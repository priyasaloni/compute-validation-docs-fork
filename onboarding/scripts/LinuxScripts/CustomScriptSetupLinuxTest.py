#!/usr/bin/env python3
import argparse
import json
import logging
import subprocess
import sys
import time
import tempfile
import uuid
import os

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s[%(levelname)s] setup_aitl_no_graph %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)

def run_cmd(cmd, check=True):
    logging.debug("Running: %s", " ".join(cmd))
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        logging.error("Command failed: %s", " ".join(cmd))
        logging.error("stdout: %s", proc.stdout.strip())
        logging.error("stderr: %s", proc.stderr.strip())
        if check:
            raise subprocess.CalledProcessError(
                proc.returncode, cmd, output=proc.stdout, stderr=proc.stderr
            )
    return proc.stdout.strip()


def create_role_definition(role_name, description, actions, data_actions, subscription_scope):
    return {
        "Name": role_name,
        "IsCustom": True,
        "Description": description,
        "Actions": actions,
        "NotActions": [],
        "DataActions": data_actions,
        "NotDataActions": [],
        "AssignableScopes": [subscription_scope]
    }

def ensure_role(role_def, role_name, subscription_scope, retries=5, delay=15, ready_timeout=600):
    """
    Ensure a custom role exists and is assignment-ready.
    Returns the full roleDefinitionId (ARM ID).
    """
    role_definition_id = None
    for attempt in range(1, retries + 1):
        tmp_path = None
        try:
            # Check if role already exists
            existing = run_cmd(["az", "role", "definition", "list", "--custom-role-only", "true"])
            roles = json.loads(existing) if existing else []
            match = next((r for r in roles if r.get("roleName") == role_name), None)
            if match:
                logging.info("Role %s already exists.", role_name)
                role_definition_id = match["id"]
                break


            # Create role if not found
            logging.info("Role %s does not exist. Creating...", role_name)
            with tempfile.NamedTemporaryFile("w", delete=False, suffix=".json", encoding="utf-8") as tmp:
                json.dump(role_def, tmp, indent=2)
                tmp_path = tmp.name


            run_cmd(["az", "role", "definition", "create", "--role-definition", tmp_path])


            # Poll for visibility
            for _ in range(20):
                time.sleep(30)
                try:
                    existing = run_cmd(["az", "role", "definition", "list", "--custom-role-only", "true"])
                    roles = json.loads(existing) if existing else []
                    match = next((r for r in roles if r.get("roleName") == role_name), None)
                    if match:
                        logging.info("Role %s successfully created and visible.", role_name)
                        role_definition_id = match["id"]
                        break
                except subprocess.CalledProcessError:
                    logging.debug("Role visibility check failed, will retry...")
                logging.info("Waiting for role %s to propagate...", role_name)
            else:
                raise RuntimeError(f"Role {role_name} not visible after create/update")


        except subprocess.CalledProcessError as e:
            logging.warning("Attempt %d/%d: Failed to ensure role %s (reason: %s)", attempt, retries, role_name, e)
            if attempt < retries:
                logging.info("Retrying in %d seconds...", delay)
                time.sleep(delay)
                continue
            else:
                raise
        finally:
            if tmp_path and os.path.exists(tmp_path):
                os.remove(tmp_path)


        # Extra check: ensure role is assignment-ready
        logging.info("Verifying role %s is assignment-ready...", role_name)
        start_time = time.time()
        while time.time() - start_time < ready_timeout:
            try:
                run_cmd([
                "az", "role", "assignment", "list",
                "--role", role_name,
                "--scope", subscription_scope
                ])
                logging.info("Role %s is assignment-ready.", role_name)
                return role_definition_id
            except subprocess.CalledProcessError:
                logging.info("Role %s not yet assignment-ready, retrying...", role_name)
                time.sleep(delay)

        raise RuntimeError(f"Role {role_name} not assignment-ready after {ready_timeout} seconds")

    return role_definition_id

def get_role_assignments_rest(principal_id, role_definition_id, scope):
    """
    Query role assignments via az rest to avoid Graph API.
    Returns list of matching assignments.
    """
    uri = (
        f"https://management.azure.com{scope}/providers/Microsoft.Authorization/roleAssignments"
        f"?api-version=2022-04-01&$filter=atScope()"
    )
    output = run_cmd(["az", "rest", "--method", "GET", "--uri", uri])
    result = json.loads(output) if output else {}
    assignments = result.get("value", [])
    return [a for a in assignments if (
        a["properties"]["principalId"] == principal_id and
        a["properties"]["roleDefinitionId"].endswith(role_definition_id)
    )]


def create_role_assignment_rest(principal_id, role_definition_id, scope, principal_type="ServicePrincipal"):
    """
    Create a role assignment using az rest.
    """
    role_assignment_id = str(uuid.uuid4())
    uri = (
        f"https://management.azure.com{scope}/providers/Microsoft.Authorization/roleAssignments/{role_assignment_id}"
        f"?api-version=2022-04-01"
    )
    body = json.dumps({
        "properties": {
            "roleDefinitionId": role_definition_id,
            "principalId": principal_id,
            "principalType": principal_type
        }
    })
    run_cmd(["az", "rest", "--method", "PUT", "--uri", uri, "--body", body])
    return role_assignment_id


def ensure_assignment(role_definition_id, role_name, assignee_object_id, scope, principal_type="ServicePrincipal",
    retries=7, delay=10, verify_attempts=10, verify_delay=15):
    """
    Ensure that the given assignee has the specified role assignment at the given scope.
    Uses az rest for role assignments to avoid Graph API.
    """
    logging.info(f"Step: Ensuring role assignment of {role_name} to {assignee_object_id}")


    role_def_guid = role_definition_id.split("/")[-1]


    for attempt in range(1, retries + 1):
        try:
            # Check existing assignments via REST
            assignments = get_role_assignments_rest(assignee_object_id, role_def_guid, scope)
            if assignments:
                logging.info(f"Role {role_name} already assigned to {assignee_object_id}")
                return


            # Create assignment via REST
            create_role_assignment_rest(assignee_object_id, role_definition_id, scope, principal_type)
            logging.info(f"Created role assignment for {role_name} on {assignee_object_id}")


            # Verify propagation
            for i in range(verify_attempts):
                time.sleep(verify_delay)
                assignments = get_role_assignments_rest(assignee_object_id, role_def_guid, scope)
                if assignments:
                    logging.info(f"Role {role_name} assignment successfully verified for {assignee_object_id}")
                    return
                logging.info(f"Waiting for assignment of {role_name} to propagate...")


            raise RuntimeError(f"Assignment of {role_name} not visible after {verify_attempts * verify_delay} seconds")


        except Exception as e:
            logging.error(
            f"Attempt {attempt}/{retries}: Failed to assign role {role_name} to {assignee_object_id} (reason: {e})"
            )
            if attempt < retries:
                logging.info(f"Retrying in {delay} seconds...")
                time.sleep(delay)
            else:
                raise

    return

def main():
    parser = argparse.ArgumentParser(description="Setup AITL roles and assignments without Graph API")
    parser.add_argument("--subscription-id", required=True, help="Subscription ID")
    parser.add_argument("--validate-spn", required=True, help="Validate SPN ObjectId")
    parser.add_argument("--aitl-spn", required=True, help="AITL SPN ObjectId")
    args = parser.parse_args()

    subscription_scope = f"/subscriptions/{args.subscription_id}"
    suffix = str(uuid.uuid4())
    aitl_role_name = f"AITL Delegator_{suffix}"
    aitl_jobs_role_name = f"AITL Jobs Access_{suffix}"

    logging.info("Script parameters:")
    logging.info("  AITL Role Name: %s", aitl_role_name)
    logging.info("  AITL Jobs Role Name: %s", aitl_jobs_role_name)
    logging.info("  AITL SPN ObjectId: %s", args.aitl_spn)
    logging.info("  Validate SPN ObjectId: %s", args.validate_spn)
    logging.info("  Subscription scope: %s", subscription_scope)

    # login context
    whoami = run_cmd(["az", "account", "show"])
    logging.info("Logged in as: %s", json.loads(whoami)["user"]["name"])
    sub_info = run_cmd(["az", "account", "show", "--subscription", args.subscription_id])
    logging.info("Current subscription: %s", json.loads(sub_info)["name"])
    logging.info("="*60)

    # AITL Delegator role
    delegator_actions = [
        "Microsoft.Resources/subscriptions/resourceGroups/read",
        "Microsoft.Resources/subscriptions/resourceGroups/write",
        "Microsoft.Resources/subscriptions/resourceGroups/delete",
        "Microsoft.Resources/deployments/read",
        "Microsoft.Resources/deployments/write",
        "Microsoft.Resources/deployments/validate/action",
        "Microsoft.Resources/deployments/operationStatuses/read",
        "Microsoft.Compute/virtualMachines/read",
        "Microsoft.Compute/virtualMachines/write",
        "Microsoft.Compute/virtualMachines/retrieveBootDiagnosticsData/action",
        # for availability set testing
        "Microsoft.Compute/availabilitySets/write",
        # for verify GPU PCI device count should be same after stop-start
        "Microsoft.Compute/virtualMachines/start/action",
        "Microsoft.Compute/virtualMachines/restart/action",
        "Microsoft.Compute/virtualMachines/deallocate/action",
        "Microsoft.Compute/virtualMachines/powerOff/action",
        # for testing hot adding disk
        "Microsoft.Compute/disks/read",
        "Microsoft.Compute/disks/write",
        "Microsoft.Compute/disks/delete",
        "Microsoft.Compute/images/read",
        "Microsoft.Compute/images/write",
        # for testing ARM64 VHD and gallery image
        "Microsoft.Compute/galleries/images/read",
        "Microsoft.Compute/galleries/images/write",
        "Microsoft.Compute/galleries/images/delete",
        "Microsoft.Compute/galleries/images/versions/read",
        "Microsoft.Compute/galleries/images/versions/write",
        "Microsoft.Compute/galleries/images/versions/delete",
        "Microsoft.Compute/galleries/read",
        "Microsoft.Compute/galleries/write",
        # for test VM extension running
        "Microsoft.Compute/virtualMachines/extensions/read",
        "Microsoft.Compute/virtualMachines/extensions/write",
        "Microsoft.Compute/virtualMachines/extensions/delete",
        # for verify_vm_assess_patches
        "Microsoft.Compute/virtualMachines/assessPatches/action",
        # for VM resize test suite
        "Microsoft.Compute/virtualMachines/vmSizes/read",
        # For disk_support_restore_point & verify_vmsnapshot_extension
        "Microsoft.Compute/restorePointCollections/write",
        # For verify_vmsnapshot_extension
        "Microsoft.Compute/restorePointCollections/restorePoints/read",
        "Microsoft.Compute/restorePointCollections/restorePoints/write",
        "Microsoft.ManagedIdentity/userAssignedIdentities/write",
        # For verify_azsecpack
        "Microsoft.ManagedIdentity/userAssignedIdentities/assign/action",
        "Microsoft.Network/virtualNetworks/read",
        "Microsoft.Network/virtualNetworks/write",
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/publicIPAddresses/read",
        "Microsoft.Network/publicIPAddresses/write",
        "Microsoft.Network/publicIPAddresses/join/action",
        "Microsoft.Network/networkInterfaces/read",
        "Microsoft.Network/networkInterfaces/write",
        "Microsoft.Network/networkInterfaces/join/action",
        # for verify_dpdk_l3fwd_ntttcp_tcp to set up Azure route table
        "Microsoft.Network/routeTables/read",
        "Microsoft.Network/routeTables/write",
        # for verify_azure_file_share_nfs mount and delete
        "Microsoft.Network/privateEndpoints/write",
        "Microsoft.Network/privateLinkServices/PrivateEndpointConnectionsApproval/action",  # noqa: E501
        # for verify_serial_console write operation
        "Microsoft.SerialConsole/serialPorts/write",
        # For setting firewall rules to access Microsoft tenant VMs
        "Microsoft.Network/networkSecurityGroups/write",
        "Microsoft.Network/networkSecurityGroups/read",
        "Microsoft.Network/networkSecurityGroups/join/action",
        "Microsoft.Storage/storageAccounts/read",
        "Microsoft.Storage/storageAccounts/write",
        "Microsoft.Storage/storageAccounts/listKeys/action",
        "Microsoft.Storage/storageAccounts/blobServices/containers/delete",
        "Microsoft.Storage/storageAccounts/blobServices/containers/read",
        "Microsoft.Storage/storageAccounts/blobServices/containers/write",
        "Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action",  # noqa: E501
    ]
    delegator_data_actions = [
        "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete",
        "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",
        "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write",
        "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action"
    ]

    delegator_role = create_role_definition(
        role_name=aitl_role_name,
        description="Delegation role is to run test cases and upload logs in Azure Image Testing for Linux (AITL).",
        actions=delegator_actions,
        data_actions=delegator_data_actions,
        subscription_scope=subscription_scope
    )

    delegator_role_id = ensure_role(delegator_role, aitl_role_name, subscription_scope)
    ensure_assignment(delegator_role_id, aitl_role_name, args.aitl_spn, subscription_scope)

    # AITL Jobs Access role
    jobs_actions = [
        "Microsoft.AzureImageTestingForLinux/jobTemplates/read",
        "Microsoft.AzureImageTestingForLinux/jobTemplates/write",
        "Microsoft.AzureImageTestingForLinux/jobTemplates/delete",
        "Microsoft.AzureImageTestingForLinux/jobs/read",
        "Microsoft.AzureImageTestingForLinux/jobs/write",
        "Microsoft.AzureImageTestingForLinux/jobs/delete",
        "Microsoft.AzureImageTestingForLinux/operations/read",
        "Microsoft.Resources/subscriptions/read",
        "Microsoft.Resources/subscriptions/operationresults/read",
        "Microsoft.Resources/subscriptions/resourcegroups/write",
        "Microsoft.Resources/subscriptions/resourcegroups/read",
        "Microsoft.Resources/subscriptions/resourcegroups/delete"
    ]
    jobs_role = create_role_definition(
        role_name=aitl_jobs_role_name,
        description="Job access role for Azure Image Testing for Linux (AITL).",
        actions=jobs_actions,
        data_actions=[],
        subscription_scope=subscription_scope
    )

    jobs_role_id = ensure_role(jobs_role, aitl_jobs_role_name, subscription_scope)
    ensure_assignment(jobs_role_id, aitl_jobs_role_name, args.validate_spn, subscription_scope)

    logging.info("Script completed successfully ✅")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        logging.error("Script failed: %s", e)
        sys.exit(1)
