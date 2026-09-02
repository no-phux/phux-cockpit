#!/usr/bin/env python3
"""Parse and verify the canonical Phux client FFI provenance lock."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
LOCK_PATH = ROOT / "phux-ffi.lock.json"
WORKFLOWS = (
    ROOT / ".github/workflows/ci.yml",
    ROOT / ".github/workflows/release.yml",
    ROOT / ".github/workflows/sdk-head.yml",
)
LOCK_KEYS = {
    "schema",
    "repository",
    "commit",
    "workspace_version",
    "client_abi_version",
    "cargo_profile",
}
OUTPUT_COMMAND = './scripts/verify-phux-ffi.py --github-output "$GITHUB_OUTPUT"'
CHECKOUT_REPOSITORY = "repository: ${{ steps.phux.outputs.repository }}"
CHECKOUT_REF = "ref: ${{ steps.phux.outputs.ref }}"
CHECKOUT_COMMAND = "./scripts/verify-phux-ffi.py --phux-tree .phux"
PROFILE_EXPRESSION = "${{ steps.phux.outputs.profile }}"


class VerificationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def path_label(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise VerificationError(f"cannot read {path_label(path)}: {error}") from error


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(read_text(path))
    except json.JSONDecodeError as error:
        raise VerificationError(f"{label} is not valid JSON: {error}") from error
    require(isinstance(value, dict), f"{label} must be a JSON object")
    return value


def load_lock() -> dict[str, Any]:
    lock = load_json(LOCK_PATH, "Phux FFI lock")
    require(set(lock) == LOCK_KEYS, "Phux FFI lock has unexpected or missing keys")
    require(type(lock["schema"]) is int and lock["schema"] == 1, "lock schema must be 1")
    require(
        isinstance(lock["repository"], str)
        and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", lock["repository"]),
        "lock repository must be an owner/name GitHub repository",
    )
    require(
        isinstance(lock["commit"], str) and re.fullmatch(r"[0-9a-f]{40}", lock["commit"]),
        "lock commit must be a full lowercase Git commit",
    )
    require(
        isinstance(lock["workspace_version"], str)
        and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", lock["workspace_version"]),
        "lock workspace_version must be a semantic version",
    )
    require(
        type(lock["client_abi_version"]) is int and lock["client_abi_version"] > 0,
        "lock client_abi_version must be a positive integer",
    )
    require(
        isinstance(lock["cargo_profile"], str)
        and re.fullmatch(r"[a-z][a-z0-9-]*", lock["cargo_profile"]),
        "lock cargo_profile must be a Cargo profile name",
    )
    return lock


def normalized(text: str) -> str:
    return " ".join(text.split())


def markdown_section(text: str, heading: str, label: str) -> str:
    match = re.search(
        rf"(?ms)^## {re.escape(heading)}\s*$\n(.*?)(?=^## |\Z)", text
    )
    require(match is not None, f"{label} is missing the '{heading}' section")
    return match.group(1)


def check_readme(lock: dict[str, Any]) -> None:
    section = markdown_section(read_text(ROOT / "README.md"), "Phux FFI provenance", "README")
    values = (
        f"`{lock['repository']}@{lock['commit'][:8]}`",
        f"workspace version `{lock['workspace_version']}`",
        f"`PHUX_CLIENT_ABI_VERSION={lock['client_abi_version']}`",
        f"Cargo profile `{lock['cargo_profile']}`",
        f"https://github.com/{lock['repository']}/commit/{lock['commit']}",
    )
    flattened = normalized(section)
    for value in values:
        require(value in flattened, f"README Phux FFI provenance is missing {value}")
    commits = set(re.findall(r"\b[0-9a-f]{40}\b", section))
    require(commits == {lock["commit"]}, "README Phux FFI provenance commit is skewed")


def check_native_sdk_notice(notices: str) -> None:
    zon = read_text(ROOT / "build.zig.zon")
    match = re.search(
        r'\.native_sdk\s*=\s*\.\{.*?\.url\s*=\s*"https://github\.com/([^/]+/[^/]+)/archive/([0-9a-f]{40})\.tar\.gz"',
        zon,
        re.DOTALL,
    )
    require(match is not None, "cannot derive the Native SDK pin from build.zig.zon")
    expected = f"Pinned source: https://github.com/{match.group(1)}/tree/{match.group(2)}"
    require(expected in notices, "THIRD_PARTY_NOTICES Native SDK pin is skewed")


def check_notices(lock: dict[str, Any]) -> None:
    notices = read_text(ROOT / "THIRD_PARTY_NOTICES.md")
    section = markdown_section(notices, "Phux Client FFI and Rust Dependencies", "THIRD_PARTY_NOTICES")
    values = (
        f"workspace version `{lock['workspace_version']}`",
        f"commit `{lock['commit']}`",
        f"ABI `{lock['client_abi_version']}`",
        f"Cargo profile `{lock['cargo_profile']}`",
        f"Source: https://github.com/{lock['repository']}/tree/{lock['commit']}",
    )
    flattened = normalized(section)
    for value in values:
        require(value in flattened, f"THIRD_PARTY_NOTICES Phux section is missing {value}")
    commits = set(re.findall(r"\b[0-9a-f]{40}\b", section))
    require(commits == {lock["commit"]}, "THIRD_PARTY_NOTICES Phux commit is skewed")
    check_native_sdk_notice(notices)


def check_license_inventory(lock: dict[str, Any]) -> None:
    path = ROOT / "assets/licenses/Phux-FFI-THIRD-PARTY.html"
    text = read_text(path)
    marker_match = re.search(r"<!-- phux-ffi-provenance: (\{.*?\}) -->", text)
    require(marker_match is not None, "Phux FFI license inventory lacks a provenance marker")
    try:
        marker = json.loads(marker_match.group(1))
    except json.JSONDecodeError as error:
        raise VerificationError(f"Phux FFI license provenance marker is invalid: {error}") from error
    require(marker == lock, "Phux FFI license inventory provenance is skewed")
    for package in ("phux-client-core", "phux-client-ffi", "phux-protocol"):
        expected = f">{package} {lock['workspace_version']}<"
        require(expected in text, f"Phux FFI license inventory has a skewed {package} version")
    canonical_url = f"https://github.com/{lock['repository']}"
    require(canonical_url in text, "Phux FFI license inventory lacks the canonical repository URL")
    require("https://github.com/phall1/phux" not in text, "Phux FFI license inventory retains the obsolete repository URL")


def check_workflow(path: Path, lock: dict[str, Any]) -> None:
    text = read_text(path)
    label = str(path.relative_to(ROOT))
    required_once = (OUTPUT_COMMAND, CHECKOUT_REPOSITORY, CHECKOUT_REF, CHECKOUT_COMMAND)
    for fragment in required_once:
        require(text.count(fragment) == 1, f"{label} must reference exactly one canonical '{fragment}'")
    require(
        not re.search(
            rf"(?<![A-Za-z0-9_.-]){re.escape(lock['repository'])}(?![A-Za-z0-9_.-])",
            text,
        ),
        f"{label} duplicates the locked Phux repository",
    )
    require(lock["commit"] not in text, f"{label} duplicates the locked Phux commit")
    require(
        not re.search(r"(?m)^\s+repository:\s+[^$\n]*phux\s*$", text),
        f"{label} hard-codes a Phux checkout repository",
    )
    output_index = text.index(OUTPUT_COMMAND)
    checkout_index = text.index(CHECKOUT_REPOSITORY)
    verify_index = text.index(CHECKOUT_COMMAND)
    cargo_index = text.index("cargo build --locked")
    require(output_index < checkout_index < verify_index < cargo_index, f"{label} must parse, checkout, verify, then build Phux")
    cargo_line = next(
        (line for line in text.splitlines() if "cargo build --locked" in line), ""
    )
    require(
        f'--profile "{PROFILE_EXPRESSION}" -p phux-client-ffi' in cargo_line,
        f"{label} must derive the Cargo profile from the lock",
    )

def check_resource_wiring() -> None:
    package = read_text(ROOT / "scripts/package-macos.sh")
    package_fragments = (
        '--write-provenance "${RESOURCES}/Phux-FFI-Provenance.json"',
        '--phux-tree "${PHUX_SOURCE_DIR}"',
        '--ffi-include-dir "${PHUX_CLIENT_FFI_INCLUDE_DIR}"',
        '--ffi-lib-dir "${PHUX_CLIENT_FFI_LIB_DIR}"',
        'verify_signature "${APP}"',
        'verify_signature "${ZIP_VERIFY}/Phux Cockpit.app"',
        'verify_signature "${DMG_MOUNT}/Phux Cockpit.app"',
    )
    for fragment in package_fragments:
        require(
            package.count(fragment) == 1,
            f"package-macos.sh must contain exactly one canonical '{fragment}'",
        )
    require("PHUX_ENABLED" not in package, "package-macos.sh permits an unattested Phux-free package")

    app_verifier = read_text(ROOT / "scripts/verify-macos-app.sh")
    require(
        app_verifier.count("Phux-FFI-Provenance.json") == 2,
        "verify-macos-app.sh must require and verify packaged Phux FFI provenance",
    )
    require(
        '--provenance-file "${RESOURCES}/Phux-FFI-Provenance.json"' in app_verifier,
        "verify-macos-app.sh does not parse packaged Phux FFI provenance",
    )


def check_repository(lock: dict[str, Any]) -> None:
    for workflow in WORKFLOWS:
        check_workflow(workflow, lock)
    check_readme(lock)
    check_notices(lock)
    check_license_inventory(lock)
    check_resource_wiring()


def cargo_section(text: str, heading: str, label: str) -> str:
    match = re.search(rf"(?ms)^\[{re.escape(heading)}\]\s*$\n(.*?)(?=^\[|\Z)", text)
    require(match is not None, f"{label} is missing [{heading}]")
    return match.group(1)


def cargo_string(section: str, key: str, label: str) -> str:
    match = re.search(rf'(?m)^{re.escape(key)}\s*=\s*"([^"]+)"\s*$', section)
    require(match is not None, f"{label} is missing {key}")
    return match.group(1)


def git_output(tree: Path, *args: str) -> str:
    result = subprocess.run(
        ("git", "-C", str(tree), *args),
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    require(result.returncode == 0, f"cannot inspect Phux checkout with git {' '.join(args)}")
    return result.stdout.strip()


def canonical_remote(value: str) -> str:
    value = value.removesuffix(".git")
    match = re.fullmatch(r"git@github\.com:(.+)", value)
    if match:
        return match.group(1)
    match = re.fullmatch(r"https?://github\.com/(.+)", value)
    return match.group(1) if match else value


def check_phux_tree(tree: Path, lock: dict[str, Any]) -> None:
    require(tree.is_dir(), f"Phux checkout does not exist: {tree}")
    require(git_output(tree, "rev-parse", "HEAD") == lock["commit"], "Phux checkout commit is skewed")
    origin = canonical_remote(git_output(tree, "remote", "get-url", "origin"))
    require(origin == lock["repository"], "Phux checkout repository is skewed")

    root_manifest = read_text(tree / "Cargo.toml")
    workspace = cargo_section(root_manifest, "workspace.package", "Phux Cargo.toml")
    require(
        cargo_string(workspace, "version", "Phux [workspace.package]") == lock["workspace_version"],
        "Phux workspace version is skewed",
    )
    cargo_section(root_manifest, f"profile.{lock['cargo_profile']}", "Phux Cargo.toml")

    ffi_manifest = read_text(tree / "crates/phux-client-ffi/Cargo.toml")
    package = cargo_section(ffi_manifest, "package", "phux-client-ffi Cargo.toml")
    require(
        re.search(r"(?m)^version\.workspace\s*=\s*true\s*$", package) is not None,
        "phux-client-ffi must inherit the locked workspace version",
    )

    lockfile = read_text(tree / "Cargo.lock")
    locked_ffi = re.search(
        r'(?m)^\[\[package\]\]\s*$\nname = "phux-client-ffi"\s*$\nversion = "([^"]+)"\s*$',
        lockfile,
    )
    require(locked_ffi is not None, "Phux Cargo.lock lacks phux-client-ffi")
    require(
        locked_ffi.group(1) == lock["workspace_version"],
        "Phux Cargo.lock phux-client-ffi version is skewed",
    )

    header = read_text(tree / "crates/phux-client-ffi/include/phux/client.h")
    abi_match = re.search(r"(?m)^#define PHUX_CLIENT_ABI_VERSION ([0-9]+)u$", header)
    profile_match = re.search(r'(?m)^#define PHUX_CLIENT_RELEASE_CARGO_PROFILE "([^"]+)"$', header)
    require(abi_match is not None, "Phux header lacks PHUX_CLIENT_ABI_VERSION")
    require(profile_match is not None, "Phux header lacks PHUX_CLIENT_RELEASE_CARGO_PROFILE")
    require(int(abi_match.group(1)) == lock["client_abi_version"], "Phux header ABI is skewed")
    require(profile_match.group(1) == lock["cargo_profile"], "Phux header Cargo profile is skewed")

def check_ffi_paths(
    tree: Path, include_dir: Path, library_dir: Path, lock: dict[str, Any]
) -> None:
    expected_include = tree / "crates/phux-client-ffi/include"
    expected_library = tree / "target" / lock["cargo_profile"]
    require(
        include_dir.resolve() == expected_include.resolve(),
        "Phux FFI include directory is not from the locked checkout",
    )
    require(
        library_dir.resolve() == expected_library.resolve(),
        "Phux FFI library directory is not from the locked checkout/profile",
    )


def compact_json(value: dict[str, Any]) -> str:
    return json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n"


def write_provenance(path: Path, lock: dict[str, Any]) -> None:
    try:
        path.write_text(compact_json(lock), encoding="utf-8")
    except OSError as error:
        raise VerificationError(f"cannot write provenance file {path}: {error}") from error


def check_provenance(path: Path, lock: dict[str, Any]) -> None:
    provenance = load_json(path, "packaged Phux FFI provenance")
    require(provenance == lock, "packaged Phux FFI provenance is skewed")


def emit_github_output(path: Path, lock: dict[str, Any]) -> None:
    values = {
        "repository": lock["repository"],
        "ref": lock["commit"],
        "version": lock["workspace_version"],
        "profile": lock["cargo_profile"],
        "abi": str(lock["client_abi_version"]),
    }
    try:
        with path.open("a", encoding="utf-8") as output:
            for key, value in values.items():
                output.write(f"{key}={value}\n")
    except OSError as error:
        raise VerificationError(f"cannot write GitHub outputs to {path}: {error}") from error


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-output", type=Path, help="append canonical values as GitHub step outputs")
    parser.add_argument("--phux-tree", type=Path, help="verify a checked-out Phux source tree")
    parser.add_argument("--provenance-file", type=Path, help="verify packaged provenance against the lock")
    parser.add_argument("--write-provenance", type=Path, help="write compact packaged provenance")
    parser.add_argument("--ffi-include-dir", type=Path, help="verify the consumed FFI include directory")
    parser.add_argument("--ffi-lib-dir", type=Path, help="verify the consumed FFI library directory")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        lock = load_lock()
        require(
            bool(args.ffi_include_dir) == bool(args.ffi_lib_dir),
            "--ffi-include-dir and --ffi-lib-dir must be supplied together",
        )
        require(
            not args.ffi_include_dir or args.phux_tree,
            "FFI artifact directories require --phux-tree",
        )
        has_operation = any(
            (args.github_output, args.phux_tree, args.provenance_file, args.write_provenance)
        )
        if not has_operation or args.github_output or args.phux_tree:
            check_repository(lock)
        if args.github_output:
            emit_github_output(args.github_output, lock)
        if args.phux_tree:
            check_phux_tree(args.phux_tree, lock)
        if args.ffi_include_dir:
            check_ffi_paths(
                args.phux_tree, args.ffi_include_dir, args.ffi_lib_dir, lock
            )
        if args.provenance_file:
            check_provenance(args.provenance_file, lock)
        if args.write_provenance:
            write_provenance(args.write_provenance, lock)
    except VerificationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(
        "Phux FFI provenance verified: "
        f"repository={lock['repository']} ref={lock['commit']} "
        f"version={lock['workspace_version']} abi={lock['client_abi_version']} "
        f"profile={lock['cargo_profile']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
