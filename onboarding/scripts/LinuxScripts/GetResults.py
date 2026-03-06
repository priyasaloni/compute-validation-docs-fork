#!/usr/bin/env python3
"""
GET ExecutionPlanRun (EPR) resource for Microsoft Validate RP.

Builds ARM URI:
  https://{ArmHost}/subscriptions/{subscriptionId}/resourceGroups/{rg}/providers/Microsoft.Validate/cloudValidations/{cv}/validationExecutionPlans/{vep}/executionPlanRuns/{epr}?api-version={apiVersion}

Uses Azure CLI auth context via: az rest

Example:
  python get_execution_plan_run.py \
    --subscription-id "188751fa-ca88-42d9-bdfe-f1406e0bde62" \
    --resource-group "vrp-dev-eastus2-rg" \
    --cloud-validation "cv-dev" \
    --validation-execution-plan "vep-dev" \
    --execution-plan-run "epr-dev" \
    --arm-host "eastus2euap.management.azure.com" \
    --api-version "2026-02-01-preview" \
    --pretty --show-curl
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
from typing import Optional, Tuple


def run(cmd: list[str], *, capture: bool = True) -> Tuple[int, str]:
    """
    Run a command and return (exit_code, combined_output).
    """
    try:
        p = subprocess.run(
            cmd,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.STDOUT if capture else None,
            text=True,
            check=False,
        )
        out = (p.stdout or "").strip() if capture else ""
        return p.returncode, out
    except FileNotFoundError:
        return 127, f"Command not found: {cmd[0]}"


def ensure_az_login() -> None:
    code, out = run(["az", "account", "show"])
    if code != 0 or not out:
        print("Not logged in. Running az login...", file=sys.stderr)
        code2, out2 = run(["az", "login"])
        if code2 != 0:
            raise RuntimeError(f"az login failed:\n{out2}")


def set_subscription(subscription_id: str) -> None:
    code, out = run(["az", "account", "set", "--subscription", subscription_id])
    if code != 0:
        raise RuntimeError(f"Failed to set subscription {subscription_id}:\n{out}")


def normalize_arm_host(host: str) -> str:
    host = host.strip()
    host = re.sub(r"^https?://", "", host, flags=re.IGNORECASE)
    return host


def build_uri(
    subscription_id: str,
    resource_group: str,
    cloud_validation: str,
    vep: str,
    epr: str,
    arm_host: str,
    api_version: str,
) -> str:
    base = f"https://{normalize_arm_host(arm_host)}"
    path = (
        f"/subscriptions/{subscription_id}"
        f"/resourceGroups/{resource_group}"
        f"/providers/Microsoft.Validate"
        f"/cloudValidations/{cloud_validation}"
        f"/validationExecutionPlans/{vep}"
        f"/executionPlanRuns/{epr}"
    )
    uri = f"{base}{path}?api-version={api_version}"

    # Guardrails (same spirit as PS)
    if "subscriptions" not in uri or "api-version=" not in uri:
        raise ValueError(f"Bad URI constructed: {uri}")
    if re.search(r"\s", uri):
        raise ValueError(f"Bad URI constructed (contains whitespace): {uri}")

    return uri


def show_curl(uri: str) -> None:
    # Pull token via az like PS script
    code, tok = run(
        ["az", "account", "get-access-token", "--resource", "https://management.azure.com", "--query", "accessToken", "-o", "tsv"]
    )
    if code == 0 and tok and "ERROR" not in tok.upper():
        token = tok.strip()
        curl_cmd = f'curl -sS -X GET "{uri}" -H "Authorization: Bearer {token}" -H "Accept: application/json"'
        print("\nCURL:", file=sys.stderr)
        print(curl_cmd, file=sys.stderr)
    else:
        print("\n(ShowCurl) Failed to fetch token via az account get-access-token", file=sys.stderr)
        print(tok, file=sys.stderr)


def az_rest_get(uri: str) -> str:
    code, out = run(["az", "rest", "--method", "get", "--uri", uri, "--only-show-errors"])
    if code != 0:
        raise RuntimeError(f"az rest FAILED (exitCode {code})\n{out}")
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Get ExecutionPlanRun (EPR) for Microsoft Validate RP.")
    parser.add_argument("--subscription-id", required=True)
    parser.add_argument("--resource-group", required=True)
    parser.add_argument("--cloud-validation", required=True)
    parser.add_argument("--validation-execution-plan", required=True)
    parser.add_argument("--execution-plan-run", required=True)
    parser.add_argument("--arm-host", default="management.azure.com")
    parser.add_argument("--api-version", default="2026-02-01-preview")

    fmt = parser.add_mutually_exclusive_group()
    fmt.add_argument("--pretty", action="store_true", help="Pretty-print JSON")
    fmt.add_argument("--raw", action="store_true", help="Print raw output")

    parser.add_argument("--show-curl", action="store_true", help="Print equivalent curl command")
    parser.add_argument("--out-file", default="", help="Write response to file")

    args = parser.parse_args()

    try:
        print("Checking Azure CLI login...", file=sys.stderr)
        ensure_az_login()

        print(f"Setting subscription: {args.subscription_id}", file=sys.stderr)
        set_subscription(args.subscription_id)

        uri = build_uri(
            subscription_id=args.subscription_id,
            resource_group=args.resource_group,
            cloud_validation=args.cloud_validation,
            vep=args.validation_execution_plan,
            epr=args.execution_plan_run,
            arm_host=args.arm_host,
            api_version=args.api_version,
        )
        print(f"Calling URI: {uri}", file=sys.stderr)

        if args.show_curl:
            show_curl(uri)

        out = az_rest_get(uri)

        # Save
        if args.out_file and args.out_file.strip():
            with open(args.out_file, "w", encoding="utf-8") as f:
                f.write(out)
            print(f"Saved response to {args.out_file}", file=sys.stderr)

        # Print
        if args.raw:
            print(out)
        elif args.pretty:
            try:
                obj = json.loads(out)
                print(json.dumps(obj, indent=2, ensure_ascii=False))
            except json.JSONDecodeError:
                # If az returns non-JSON error text (shouldn't here), fallback
                print(out)
        else:
            print(out)

        return 0

    except Exception as e:
        print("\nSCRIPT FAILED", file=sys.stderr)
        print(str(e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())