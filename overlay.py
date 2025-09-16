import os
import json
import subprocess
import shutil
import sys
import re
import argparse
import tempfile

OVERLAY_DIR = "overlays"
STACK_DIR = "stacks"
RESOURCES = "$RESOURCES"

# Global overlay search paths (populated in main)
overlay_search_paths = []

def _collect_overlay_env_for_chroot():
    """Return env KEY=VAL pairs to pass into chroot (PKG_* and PIN_PRIORITY)."""
    env = {}
    for k, v in os.environ.items():
        if k.startswith("PKG_") or k == "PIN_PRIORITY":
            env[k] = v
    return env

def _env_prefix(env_dict):
    # Build 'KEY="VALUE" KEY2="VALUE2"' safely for shell
    return " ".join(f'{k}="{v}"' for k, v in env_dict.items())

def remove_json_comments(json_string):
    """Remove comments from JSON string."""
    json_string = re.sub(r"//.*", "", json_string)
    json_string = re.sub(r"/\*.*?\*/", "", json_string, flags=re.DOTALL)
    return json_string

def json_load_and_support_comments(file):
    print(f"Loading JSON file with comments: {file}")
    with open(file, "r") as f:
        json_content = f.read()
        json_content = remove_json_comments(json_content)
        data = json.loads(json_content)
    return data

def validate_overlay(json_data):
    """Validate the structure of an overlay JSON file."""
    required_keys = {"name", "description", "commands"}
    if not isinstance(json_data, dict):
        print("Not a dictionary")
        return False
    if not required_keys.issubset(json_data.keys()):
        print(f"Missing required keys: {required_keys - json_data.keys()}")
        return False
    if not isinstance(json_data["commands"], list):
        print("Commands is not a list")
        return False
    for command in json_data["commands"]:
        if "type" not in command or command["type"] not in {"local", "copy-into-chroot", "copy-from-chroot", "chroot-cmd", "chroot-script", "chroot-rm", "chroot-install-package"}:
            print(f"Invalid command type: {command.get('type')}")
            return False
        if command["type"] in {"local", "chroot-script"} and "script" not in command:
            print("Missing script key")
            return False
        if command["type"] in {"copy-into-chroot", "copy-from-chroot"} and not {"source", "destination"}.issubset(command.keys()):
            print("Missing source or destination key")
            return False
        if command["type"] == "chroot-cmd" and "cmd" not in command:
            print("Missing cmd key")
            return False
        if command["type"] == "chroot-rm" and "destination" not in command:
            print("Missing destination key")
            return False
        if command["type"] == "chroot-install-package" and "package" not in command:
            print("Missing package key")
            return False
    return True

def validate_stack(json_data):
    """Validate the structure of a stack JSON file and print errors when validation fails."""
    required_keys = {"name", "description", "steps"}
    if not isinstance(json_data, dict):
        print("Error: JSON data is not a dictionary.", json_data)
        return False
    missing_keys = required_keys - json_data.keys()
    if missing_keys:
        print(f"Error: Missing required keys: {missing_keys}", json_data)
        return False
    if not isinstance(json_data["steps"], list):
        print("Error: 'steps' must be a list.", json_data["steps"])
        return False
    for i, step in enumerate(json_data["steps"]):
        if not isinstance(step, dict):
            print(f"Error: Step {i} is not a dictionary.", step)
            return False
        if "type" not in step:
            print(f"Error: Step {i} is missing 'type' key.", step)
            return False
        if step["type"] not in {"overlay", "stack"}:
            print(f"Error: Step {i} has invalid 'type'. Must be 'overlay' or 'stack'.", step)
            return False
        if step["type"] == "overlay" and "name" not in step:
            print(f"Error: Step {i} of type 'overlay' is missing 'name' key.", step)
            return False
        if step["type"] == "stack" and "name" not in step:
            print(f"Error: Step {i} of type 'stack' is missing 'name' key.", step)
            return False
    return True

def list_overlays(verbose=False):
    """List all overlays based on their JSON files, optionally show details."""
    overlays = []
    seen = set()
    for base in overlay_search_paths:
        overlays_dir = os.path.join(base, OVERLAY_DIR)
        if not os.path.isdir(overlays_dir):
            continue
        for overlay_name in os.listdir(overlays_dir):
            overlay_path = os.path.join(overlays_dir, overlay_name)
            json_file = os.path.join(overlay_path, "overlay.json")
            if os.path.isdir(overlay_path) and os.path.isfile(json_file):
                try:
                    overlay_data = json_load_and_support_comments(json_file)
                    if validate_overlay(overlay_data):
                        if overlay_data["name"] not in seen:
                            overlays.append((overlay_data, overlay_path))
                            seen.add(overlay_data["name"])
                        else:
                            pass  # duplicate name, skip
                    else:
                        print(f"Invalid overlay JSON: {json_file}")
                except json.JSONDecodeError as e:
                    print(f"Error reading JSON in {json_file}: {e}")
    print("Available overlays:")
    for overlay_data, overlay_path in overlays:
        print(f"- {overlay_data['name']}: {overlay_path}")
        if verbose:
            print(f"\n  JSON Contents for {overlay_data['name']}:")
            print(json.dumps(overlay_data, indent=2))
            for command in overlay_data["commands"]:
                if command["type"] in {"local", "chroot-script"}:
                    script_path = os.path.join(overlay_path, command["script"])
                    if os.path.isfile(script_path):
                        print(f"\n  Script ({command['type']}): {script_path}")
                        with open(script_path, "r") as script_file:
                            print(script_file.read())
                elif command["type"] in {"copy-into-chroot", "copy-from-chroot"}:
                    print(f"\n  Copy Task ({command['type']}):")
                    print(f"    Source: {command['source']}")
                    print(f"    Destination: {command['destination']}")
                elif command["type"] == "chroot-cmd":
                    print(f"\n  Command (chroot-cmd): {command['cmd']}")
                elif command["type"] == "chroot-rm":
                    print(f"\n  Command (chroot-rm): {command['destination']}")
                elif command["type"] == "chroot-install-package":
                    print(f"\n  Command (chroot-install-package): {command['package']}")
                else:
                    print(f"\n  Unknown command type: {command['type']}")

def list_stacks(verbose=False):
    """List all stacks based on their JSON files, optionally show details."""
    stacks = []
    seen = set()
    for base in overlay_search_paths:
        stack_dir = os.path.join(base, STACK_DIR)
        if not os.path.isdir(stack_dir):
            continue
        for filename in os.listdir(stack_dir):
            if not filename.endswith(".json"):
                continue
            stack_path = os.path.join(stack_dir, filename)
            try:
                stack_data = json_load_and_support_comments(stack_path)
                if validate_stack(stack_data):
                    name = stack_data["name"]
                    if name not in seen:
                        stacks.append((stack_data, stack_path))
                        seen.add(name)
                else:
                    print(f"Invalid stack JSON: {stack_path}")
            except json.JSONDecodeError as e:
                print(f"Error reading JSON in {stack_path}: {e}")
    print("Available stacks:")
    for stack_data, stack_path in stacks:
        print(f"- {stack_data['name']}: {stack_path}")
        if verbose:
            print(f"\n  JSON Contents for {stack_data['name']}:")
            print(json.dumps(stack_data, indent=2))

def apply_stack(mount_point, stack_path, resources):
    """Apply a stack by processing its JSON file."""
    if not os.path.isfile(stack_path):
        print(f"Stack not found: {stack_path}")
        sys.exit(1)
    print(f"Applying stack: {stack_path}")
    stack_data = json_load_and_support_comments(stack_path)
    if not validate_stack(stack_data):
        print(f"Invalid stack file: {stack_path}")
        sys.exit(1)
    for step in stack_data["steps"]:
        process_stack_step(mount_point, step, resources)

def process_stack_step(mount_point, step, resources):
    """Process a single step in a stack."""
    print(f"->> Processing stack step: {step['name']} with {step}")
    if "enabled" in step and not step["enabled"]:
        print(f"Skipping disabled stack step: {step['name']}")
        return
    if step["type"] == "overlay":
        found = False
        for base in overlay_search_paths:
            overlay_dir = os.path.join(base, OVERLAY_DIR, step["name"])
            if os.path.isdir(overlay_dir):
                apply_overlay(mount_point, overlay_dir, resources)
                found = True
                break
        if not found:
            print(f"Error: overlay '{step['name']}' not found in overlay paths.")
            sys.exit(1)
    elif step["type"] == "stack":
        found = False
        for base in overlay_search_paths:
            stack_file = os.path.join(base, STACK_DIR, step["name"] + ".json")
            if os.path.isfile(stack_file):
                apply_stack(mount_point, stack_file, resources)
                found = True
                break
        if not found:
            print(f"Error: stack '{step['name']}.json' not found in overlay paths.")
            sys.exit(1)
    else:
        print(f"Unknown stack step type: {step['type']}")
        sys.exit(1)

def run_local_script(script_path, temp_dir):
    """Run a script on the host."""
    print(f"Running local script: {script_path}")
    result = subprocess.run([script_path, temp_dir], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        print(f"Error in local script {script_path}: {result.stderr.decode()}")
        sys.exit(1)

def replace_resources(path, resources):
    """Replace the $RESOURCES placeholder in a path."""
    print(f"Replacing resources placeholder path: {path} and resources: {resources}")
    if resources and RESOURCES in path:
        path = path.replace(RESOURCES, resources)
    return path

def copy_files(source, destination, mount_point, resources, into_chroot=True, permissions="644"):
    """Copy files into or out of the chroot environment, applying optional permissions."""
    print(f"Copying files from {source} to {destination} (into_chroot={into_chroot}) using mount_point: {mount_point}")
    if into_chroot:
        dest_path = os.path.join(mount_point, destination.lstrip("/"))
        source_path = source
        print(f"into_chroot: Copying files from {source} to {dest_path}")
    else:
        source_path = os.path.join(mount_point, source.lstrip("/"))
        dest_path = destination
        print(f"NOT into_chroot: Copying files from {source_path} to {dest_path}")
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    try:
        subprocess.run(f"sudo cp -r {source_path} {dest_path}", shell=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"Error copying file from {source} to {destination}: {e}")
        sys.exit(1)
    if into_chroot:
        try:
            subprocess.run(f"sudo chmod {permissions} {dest_path}", shell=True, check=True)
        except subprocess.CalledProcessError:
            print(f"Error: Failed to set permissions to {permissions} for {dest_path}.")
            sys.exit(1)

def install_package(mount_point, resources, package):
    """Install a package inside the chroot environment."""
    print(f"Installing package: {package}")
    try:
        subprocess.run(["sudo", "chroot", mount_point, "/bin/bash", "-c", f"apt-get install --no-install-recommends -y {package}"], check=True)
    except subprocess.CalledProcessError as e:
        print(f"Error installing package {package}: {e}")
        sys.exit(1)

def delete_files(destination, mount_point, resources):
    """Delete files from the chroot environment."""
    print(f"Deleting files from {destination} using mount_point: {mount_point}")
    dest_path = os.path.join(mount_point, destination.lstrip("/"))
    print(f"Deleting files from {dest_path}")
    try:
        subprocess.run(f"sudo rm -rf {dest_path}", shell=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"Error deleting file from {destination}: {e}")
        sys.exit(1)

def run_chroot_cmd(cmd, mount_point, ignore_errors=False):
    """Run a direct command inside the chroot (force noninteractive)."""
    env_prefix = _env_prefix(_collect_overlay_env_for_chroot())
    full_cmd = f"sudo chroot {mount_point} /usr/bin/env DEBIAN_FRONTEND=noninteractive {env_prefix} /bin/bash -lc \"{cmd}\""
    print(f"Running chroot command: {cmd}")
    try:
        subprocess.run(full_cmd, shell=True, check=True)
    except subprocess.CalledProcessError as e:
        if ignore_errors:
            print(f"Ignoring error in chroot command: {cmd}")
            return
        print(f"Error in chroot command: {cmd}\n{e}")
        sys.exit(1)

def run_chroot_script(script_path, mount_point):
    """Copy a script into the chroot and execute it; strict cleanup afterwards."""
    print(f"Running chroot script: {script_path}")

    # Ensure /tmp exists in the chroot
    try:
        subprocess.run(f"sudo mkdir -p {mount_point}/tmp", shell=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"Error creating {mount_point}/tmp in chroot: {e}")
        sys.exit(1)

    dst_in_chroot_host = f"{mount_point}/tmp/chroot-script"  # host view of the chroot path
    dst_in_chroot      = "/tmp/chroot-script"                # path inside chroot

    # Copy script into the chroot
    print(f"Copying script into root from {script_path} to {dst_in_chroot_host}")
    try:
        subprocess.run(f"sudo cp {script_path} {dst_in_chroot_host}", shell=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"Error copying script to chroot: {e}")
        sys.exit(1)

    # Make executable
    print(f"Making {dst_in_chroot_host} executable")
    try:
        subprocess.run(f"sudo chmod +x {dst_in_chroot_host}", shell=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"Error making script executable: {e}")
        sys.exit(1)

    # Run script inside the chroot (noninteractive env suggested elsewhere)
    print(f"Running script inside chroot: {dst_in_chroot}")
    try:
        env_prefix = _env_prefix(_collect_overlay_env_for_chroot())
        subprocess.run(
            f"sudo chroot {mount_point} /usr/bin/env DEBIAN_FRONTEND=noninteractive {env_prefix} /bin/bash -lc '/tmp/chroot-script'",
            shell=True,
            check=True
        )
    except subprocess.CalledProcessError as e:
        print(f"Error running chroot script {script_path}: {e}")
        sys.exit(1)

    # Strict cleanup: fail if the temp script is missing or cannot be removed
    print("Removing the tmp script from the chroot (strict)...")
    try:
        # If the file disappeared (e.g., script self-deleted), treat that as an error
        if not os.path.exists(dst_in_chroot_host):
            print(f"Error: expected {dst_in_chroot_host} to exist for cleanup, but it does not.")
            sys.exit(1)
        subprocess.run(f"sudo rm {dst_in_chroot_host}", shell=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"Error: Failed to remove temp script: {e}")
        sys.exit(1)

def apply_overlay(mount_point, overlay_path, resources):
    """Apply an overlay by processing its JSON file."""
    print(f"Applying overlay: {overlay_path} with resources {resources}")
    file_name = os.path.join(overlay_path, "overlay.json")
    overlay_data = json_load_and_support_comments(file_name)
    temp_dir = tempfile.mkdtemp()
    for command in overlay_data["commands"]:
        if command["type"] == "local":
            script_path = os.path.join(overlay_path, command["script"])
            run_local_script(script_path, temp_dir)
        elif command["type"] == "copy-into-chroot":
            if RESOURCES in command["source"]:
                path = command["source"].replace(RESOURCES, resources) if resources else command["source"]
            else:
                path = os.path.join(overlay_path, command["source"])
            permissions = command.get("permissions", "644")
            if "permissions" not in command:
                print(f"Warning: No permissions specified for {command['source']}.")
                sys.exit(1)
            copy_files(path, command["destination"], mount_point, resources, into_chroot=True, permissions=permissions)
        elif command["type"] == "copy-from-chroot":
            if RESOURCES in command["destination"]:
                path = command["destination"].replace(RESOURCES, resources) if resources else command["destination"]
            else:
                path = os.path.join(overlay_path, command["destination"])
            copy_files(command["source"], path, mount_point, resources, into_chroot=False)
        elif command["type"] == "chroot-cmd":
            ignore_errors = command.get("ignore-errors", False)
            run_chroot_cmd(command["cmd"], mount_point, ignore_errors)
        elif command["type"] == "chroot-script":
            script_path = os.path.join(overlay_path, command["script"])
            run_chroot_script(script_path, mount_point)
        elif command["type"] == "chroot-rm":
            delete_files(command["destination"], mount_point, resources)
        elif command["type"] == "chroot-install-package":
            install_package(mount_point, resources, command["package"])
        else:
            print(f"Unknown command type: {command['type']}")
    shutil.rmtree(temp_dir)

def main():
    parser = argparse.ArgumentParser(description="Tachyon Overlay and Stack Manager")
    parser.add_argument("--mount-point", required=False, help="Mount point for the chroot")
    parser.add_argument("--verbose", action="store_true", help="Verbose output")
    parser.add_argument("--overlay", help="Name of the overlay to apply")
    parser.add_argument("--stack", help="Name of the stack to apply")
    parser.add_argument("--resources", help="Path to optional resources needed for overlays")
    parser.add_argument("--overlay-dirs", help="Colon-separated list of directories to search for overlays and stacks")
    parser.add_argument("command", choices=["list-overlays", "list-stacks", "apply"], help="Command to execute")
    args = parser.parse_args()

    #print out all args
    print("Arguments:")
    for arg, value in vars(args).items():
        print(f"  {arg}: {value}")

    global overlay_search_paths
    if getattr(args, 'overlay_dirs', None):
        overlay_search_paths = [os.path.abspath(p) for p in args.overlay_dirs.split(':')]
        for d in overlay_search_paths:
            if not os.path.isdir(d):
                print(f"Error: Overlay directory not found: {d}")
                sys.exit(1)
    else:
        overlay_search_paths = [os.getcwd()]
    
    #print overlay_search_paths
    print("Overlay search paths:")
    for p in overlay_search_paths:
        print(f" - {p}")

    if args.command == "list-overlays":
        list_overlays(verbose=args.verbose)
    elif args.command == "list-stacks":
        list_stacks(verbose=args.verbose)
    elif args.command == "apply":
        if not args.mount_point:
            print("Error: --mount-point is required for the 'apply' command.")
            sys.exit(1)
        if args.overlay and args.stack:
            print("Error: Specify only one of --overlay or --stack for the 'apply' command.")
            sys.exit(1)
        if not args.overlay and not args.stack:
            print("Error: Either --overlay or --stack is required for the 'apply' command.")
            sys.exit(1)
        if args.overlay:
            found = False
            for base in overlay_search_paths:
                overlay_dir = os.path.join(base, OVERLAY_DIR, args.overlay)
                if os.path.isdir(overlay_dir):
                    apply_overlay(args.mount_point, overlay_dir, args.resources or "")
                    found = True
                    break
            if not found:
                print(f"Error: Overlay '{args.overlay}' not found in given overlay directories.")
                sys.exit(1)
        elif args.stack:
            found = False
            for base in overlay_search_paths:
                stack_file = os.path.join(base, STACK_DIR, args.stack + ".json")
                if os.path.isfile(stack_file):
                    apply_stack(args.mount_point, stack_file, args.resources or "")
                    found = True
                    break
            if not found:
                print(f"Error: Stack '{args.stack}' not found in given overlay directories.")
                sys.exit(1)
    else:
        print(f"Unknown command: {args.command}")
        sys.exit(1)

if __name__ == "__main__":
    main()