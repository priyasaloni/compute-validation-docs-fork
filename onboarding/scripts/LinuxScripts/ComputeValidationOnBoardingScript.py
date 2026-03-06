#!/usr/bin/env python3
"""
Combined Compute Validation for VM Image prerequisites:
 - Microsoft.Validate
 - Managed RG creation + RBAC for Validate RP SP
 - Linux Advanced Test prereqs (Microsoft.AzureImageTestingForLinux + Compute/Network/Storage)
 - Optional: run Linux Advanced Test permissions bootstrap script (CustomScriptSetupLinuxTest.py)

This consolidates functionality from:
 - SelfServeOnBoardingScript.ps1
 - CustomScriptLinxTest-powershell.ps1
and shares common functions (no duplication).

Example:
  python SelfServeOnBoardingScript.py \
    --subscription-id 184cdb00-9604-4154-ba2f-0c89a10710c3
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timedelta


# -------------------- Common Helpers --------------------

def write_log(level: str, message: str) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"{ts}[{level}] {message}")


def assert_exe(name: str) -> None:
    """Verify that a required executable is available on the PATH."""
    if shutil.which(name) is None:
        raise RuntimeError(f"Required executable not found: {name}")


def is_cloud_shell() -> bool:
    """Detect whether we are running inside Azure Cloud Shell."""
    return (
        os.environ.get("CLOUD_SHELL", "").lower() == "true"
        or os.environ.get("ACC_CLOUD") is not None
        or os.environ.get("AZUREPS_HOST_ENVIRONMENT", "").startswith("cloud-shell")
    )


def initialize_azure_cli_config_dir() -> None:
    """
    Avoid CLI session folder permission issues on some machines/agents.
    In Azure Cloud Shell the default ~/.azure config dir already contains
    valid session credentials, so we must NOT replace it.
    """
    if is_cloud_shell():
        write_log("DEBUG", "Azure Cloud Shell detected — using default AZURE_CONFIG_DIR")
        return

    config_dir = os.environ.get("AZURE_CONFIG_DIR", "").strip()
    if not config_dir:
        config_dir = os.path.join(
            tempfile.gettempdir(),
            "azure-config-" + uuid.uuid4().hex
        )
        os.makedirs(config_dir, exist_ok=True)
        os.environ["AZURE_CONFIG_DIR"] = config_dir
        write_log("DEBUG", f"Using AZURE_CONFIG_DIR={config_dir}")
    else:
        os.makedirs(config_dir, exist_ok=True)
        write_log("DEBUG", f"Using existing AZURE_CONFIG_DIR={config_dir}")


def invoke_az(args: list, no_throw: bool = False) -> str:
    """
    Robust AZ CLI invocation. Returns stdout as a trimmed string.
    stderr is captured separately and logged as DEBUG so it does not
    corrupt stdout or cause false failures.
    """
    write_log("DEBUG", "Running: az " + " ".join(args))

    result = subprocess.run(
        ["az"] + args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    out = result.stdout.strip() if result.stdout else ""
    err = result.stderr.strip() if result.stderr else ""

    if err:
        write_log("DEBUG", f"az stderr: {err}")

    if result.returncode != 0 and not no_throw:
        raise RuntimeError(
            f"az failed (exit={result.returncode}): az {' '.join(args)}\n{out}\n{err}"
        )

    return out


def ensure_az_login() -> None:
    """
    Check whether we already have a valid Azure CLI session.
    In Azure Cloud Shell the user is always pre-authenticated, so
    'az account show' will succeed and we skip the interactive login.
    """
    try:
        invoke_az(["account", "show", "-o", "none"])
        write_log("INFO", "Already logged into Azure CLI.")
    except RuntimeError:
        write_log("INFO", "Not logged into Azure CLI. Launching 'az login'...")
        invoke_az(["login", "-o", "none"])


def set_az_subscription(sub_id: str) -> None:
    invoke_az(["account", "set", "--subscription", sub_id])
    sub_name = invoke_az(["account", "show", "--query", "name", "-o", "tsv"])
    write_log("INFO", f"Using subscription: {sub_name} ({sub_id})")


def wait_feature(ns: str, name: str, timeout: int = 1800) -> None:
    deadline = datetime.now() + timedelta(seconds=timeout)
    while datetime.now() < deadline:
        state = invoke_az([
            "feature", "show",
            "--namespace", ns,
            "--name", name,
            "--query", "properties.state",
            "-o", "tsv",
        ]).strip()
        if state == "Registered":
            write_log("INFO", f"Feature {ns}/{name} Registered")
            return
        write_log("INFO", f"Feature {ns}/{name} state={state}; waiting...")
        time.sleep(10)
    raise RuntimeError(f"Timeout waiting feature {ns}/{name}")


def wait_provider(ns: str, timeout: int = 1800) -> None:
    deadline = datetime.now() + timedelta(seconds=timeout)
    while datetime.now() < deadline:
        state = invoke_az([
            "provider", "show",
            "--namespace", ns,
            "--query", "registrationState",
            "-o", "tsv",
        ]).strip()
        if state == "Registered":
            write_log("INFO", f"Provider {ns} Registered")
            return
        write_log("INFO", f"Provider {ns} state={state}; waiting...")
        time.sleep(10)
    raise RuntimeError(f"Timeout waiting provider {ns}")


def resolve_sp_object_id_by_app_id(app_id: str) -> str:
    obj_id = invoke_az([
        "ad", "sp", "show",
        "--id", app_id,
        "--query", "id",
        "-o", "tsv",
    ]).strip()
    if not obj_id:
        raise RuntimeError(
            f"Could not resolve service principal objectId for appId={app_id}"
        )
    return obj_id


def resolve_sp_object_id_by_display_name(name: str) -> str:
    obj_id = invoke_az([
        "ad", "sp", "list",
        "--display-name", name,
        "--query", "[0].id",
        "-o", "tsv",
    ]).strip()
    if not obj_id:
        raise RuntimeError(
            f"Could not resolve service principal objectId for displayName={name}"
        )
    return obj_id


def ensure_resource_group(rg_name: str, location: str) -> None:
    invoke_az([
        "group", "create",
        "--name", rg_name,
        "--location", location,
        "-o", "none",
    ])
    write_log("INFO", f"Resource group ensured: {rg_name} ({location})")


def ensure_role_assignment(
    scope: str,
    assignee_object_id: str,
    role_name: str,
    principal_type: str = "ServicePrincipal",
) -> None:
    """Idempotent role assignment: check first, create only if missing."""
    existing = invoke_az(
        [
            "role", "assignment", "list",
            "--assignee-object-id", assignee_object_id,
            "--scope", scope,
            "--query", f"[?roleDefinitionName=='{role_name}'] | [0].id",
            "-o", "tsv",
        ],
        no_throw=True,
    )

    if existing and existing.strip():
        write_log(
            "INFO",
            f"Role already assigned: '{role_name}' -> {assignee_object_id} on {scope}",
        )
        return

    invoke_az([
        "role", "assignment", "create",
        "--assignee-object-id", assignee_object_id,
        "--assignee-principal-type", principal_type,
        "--role", role_name,
        "--scope", scope,
        "--only-show-errors",
        "-o", "none",
    ])
    write_log("INFO", f"Role assigned: '{role_name}' -> {assignee_object_id} on {scope}")


def resolve_linux_permissions_script() -> str:
    """
    Locate the companion Python permissions script
    (CustomScriptSetupLinuxTest.py) next to this script.
    """
    script_dir = os.path.dirname(os.path.abspath(__file__))
    candidate = os.path.join(script_dir, "CustomScriptSetupLinuxTest.py")
    if os.path.isfile(candidate):
        return os.path.abspath(candidate)
    raise RuntimeError(f"Missing Linux advanced test permissions script: {candidate}")


# -------------------- MAIN --------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Combined Compute Validation for VM Image prerequisites."
    )
    parser.add_argument(
        "--subscription-id",
        required=True,
        help="Azure subscription ID.",
    )
    parser.add_argument(
        "--validate-rp-app-id-for-linux-test",
        default="f877b90d-59ee-40e3-8d2c-215dae4c80d8",
        help="Validate RP appId used by Linux Advanced Test permissions bootstrap.",
    )
    parser.add_argument(
        "--linux-sp-display-name",
        default="AzureImageTestingForLinux",
        help="Display name of the Linux Advanced Test service principal.",
    )
    parser.add_argument(
        "--no-run-linux-prereqs",
        action="store_true",
        default=False,
        help="Skip Linux prerequisite registration steps.",
    )
    parser.add_argument(
        "--no-run-linux-advanced-test-permissions-script",
        action="store_true",
        default=False,
        help="Skip running the Linux Advanced Test permissions bootstrap script.",
    )

    args = parser.parse_args()

    subscription_id = args.subscription_id
    validate_rp_app_id = args.validate_rp_app_id_for_linux_test
    linux_sp_display_name = args.linux_sp_display_name
    run_linux_prereqs = not args.no_run_linux_prereqs
    run_linux_advanced_test_permissions_script = (
        not args.no_run_linux_advanced_test_permissions_script
    )

    assert_exe("az")
    initialize_azure_cli_config_dir()
    ensure_az_login()
    set_az_subscription(subscription_id)

    # --------- RP prereqs (Microsoft.Validate + Microsoft.Resources) ---------

    write_log("INFO", "Registering Microsoft.Validate feature + provider...")
    invoke_az([
        "feature", "register",
        "--namespace", "Microsoft.Validate",
        "--name", "SelfServeVMImageValidation",
        "--only-show-errors",
    ])
    wait_feature("Microsoft.Validate", "SelfServeVMImageValidation")

    invoke_az(["provider", "register", "--namespace", "Microsoft.Validate"])
    wait_provider("Microsoft.Validate")

    invoke_az(["provider", "register", "--namespace", "Microsoft.Resources"])
    wait_provider("Microsoft.Resources")

    # --------- Linux Advanced Test prereqs ---------

    if run_linux_prereqs:
        write_log("INFO", "Registering linuxAdvancedTestSp feature + provider...")
        invoke_az([
            "feature", "register",
            "--namespace", "Microsoft.AzureImageTestingForLinux",
            "--name", "JobandJobTemplateCrud",
            "--only-show-errors",
        ])
        wait_feature("Microsoft.AzureImageTestingForLinux", "JobandJobTemplateCrud")

        invoke_az([
            "provider", "register",
            "--namespace", "Microsoft.AzureImageTestingForLinux",
            "--only-show-errors",
        ])
        wait_provider("Microsoft.AzureImageTestingForLinux")

        write_log(
            "INFO",
            "Registering dependent providers: Microsoft.Compute, Microsoft.Network, Microsoft.Storage...",
        )
        for ns in ("Microsoft.Compute", "Microsoft.Network", "Microsoft.Storage"):
            invoke_az(["provider", "register", "--namespace", ns])
            wait_provider(ns)

        write_log("INFO", "Linux prerequisites completed.")
    else:
        write_log("INFO", "Skipping Linux prereqs (RunLinuxPrereqs not set).")

    # --------- Linux Advanced Test permissions bootstrap ---------

    if run_linux_advanced_test_permissions_script:
        validate_sp = resolve_sp_object_id_by_app_id(validate_rp_app_id)
        linux_advanced_test_sp = resolve_sp_object_id_by_display_name(
            linux_sp_display_name
        )

        write_log(
            "INFO",
            f"Validate RP SP objectId (Linux Advanced Test script): {validate_sp}",
        )
        write_log(
            "INFO",
            f"Linux Advanced Test RP SP objectId: {linux_advanced_test_sp}",
        )

        perm_script = resolve_linux_permissions_script()
        write_log(
            "INFO",
            f"Running Linux Advanced Test Validation permissions bootstrap: {perm_script}",
        )

        # Run the companion Python permissions script
        result = subprocess.run(
            [
                sys.executable, perm_script,
                "--subscription-id", subscription_id,
                "--validate-spn", validate_sp,
                "--aitl-spn", linux_advanced_test_sp,
            ],
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"Linux Advanced Test permissions script failed (exit={result.returncode})"
            )

        write_log("INFO", "Linux Advanced Test permissions bootstrap completed.")
    else:
        write_log(
            "INFO",
            "Skipping Linux Advanced Test permissions bootstrap "
            "(RunLinuxAdvancedTestPermissionsScript not set).",
        )

    write_log("INFO", "All prerequisites completed successfully ✅")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        write_log("ERROR", str(e))
        sys.exit(1)