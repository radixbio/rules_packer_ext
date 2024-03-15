#!/usr/bin/python3
"""wrapper script for invoking packer."""
import hashlib
import json
import os
import sys
import platform
import argparse
import subprocess as sp
from typing import NamedTuple, List, Callable, Dict, Any
import shutil
import logging as log
import copy
import tempfile


def sha256(fpath):
    """Compute sha256 of a file in python."""
    BYTES_MAGIC = 65536
    sha = hashlib.sha256()
    if os.path.isdir(
        fpath
    ):  # HACK: since we declare an output directory, but sometimes give files
        #       (http_file)
        fpath = fpath + os.path.sep + os.path.basename(fpath)
    with open(fpath, "rb") as f:
        d = f.read(BYTES_MAGIC)
        while len(d) > 0:
            sha.update(d)
            d = f.read(BYTES_MAGIC)
    return sha.hexdigest()


class CLI_variant:
    """Utility ADT for which command line mode i'm going to use."""

    pass


class Build(CLI_variant):
    """In the Build variant, we'll do a packer build with a user supplied\
    packerfile."""

    pass


class InsertFile(CLI_variant):
    """In the InsertFile variant, we'll do a packer build but splice in\
    provisioners to insert files from the local filesystem into the VM."""

    pass


class RunScripts(CLI_variant):
    """In the RunScripts variant, packer will execute scripts in the VM."""

    pass


class RunVMs(CLI_variant):
    """In the RunVMs variant, many qemu VM"s are run, and their IP addresses\
    will be written to a file."""

    pass


class Config(NamedTuple):
    """Config for the python packer runner to set up packer invocation and\
       overwrite."""

    name: str
    architecture: str
    overwrite: bool
    packerfile: str
    out_dir: str
    var_file: str
    cli_vars: dict[str, str]
    packer_path: str
    sha256_var_name: str
    iso_img_loc: str
    env: dict[str, str]
    variant: CLI_variant

    @staticmethod
    def from_json(variant: CLI_variant) -> Callable[[Dict[str, Any]], "Config"]:
        """Parse configuration to this script from a JSON format.

        NOTE: this may not parse inner objects if the above class structure
              evolves
        """

        def loader(args):
            try:
                args.update({"variant": variant})
                return Config(**args)
            except TypeError as e:
                return args

        return loader

    @staticmethod
    def from_path(path: str, variant: CLI_variant) -> "Config":
        """Parse configuration from a JSON file."""
        ret = None
        with open(os.path.abspath(path), "rb") as f:
            input = f.read()
            ret = json.loads(input, object_hook=Config.from_json(variant))
        return ret

    def splice_files_to_transfer(self, provisioners_file) -> "Config":
        assert isinstance(self.variant, InsertFile)

        with open(os.path.abspath(self.packerfile), "rb") as packerfile_f:
            packerfile_input = packerfile_f.read()
            packerfile = json.loads(packerfile_input)
            with open(os.path.abspath(provisioners_file), "rb") as paths_f:
                paths_mapping_input = paths_f.read()
                paths_mapping = json.loads(paths_mapping_input)
                paths_mapping = [
                    {"type": "file", "source": k, "destination": v}
                    for k, v in paths_mapping.items()
                ]
                sync = [{"type": "shell", "inline": ["sync"]}]
                packerfile["provisioners"].extend(paths_mapping)
                packerfile["provisioners"].extend(sync)
                print(packerfile)
                with tempfile.NamedTemporaryFile(
                    mode="w", encoding="utf-8", delete=False
                ) as new_packerfile:
                    # Write the string to the temporary file
                    new_packerfile.write(json.dumps(packerfile, indent=2))
                    new_packerfile.flush()

                    return self._replace(
                        packerfile=os.path.abspath(new_packerfile.name)
                    )

    def splice_scripts_to_run(self, scripts, env=os.environ) -> "Config":
        assert isinstance(self.variant, RunScripts)

        with open(os.path.abspath(self.packerfile), "rb") as packerfile_f:
            packerfile_input = packerfile_f.read()
            packerfile = json.loads(packerfile_input)
            scripts_blk = [
                {"script": os.path.abspath(k), "env": dict(env), "type": "shell"}
                for k in scripts
            ]
            sync = [{"type": "shell", "inline": ["sync"]}]
            packerfile["provisioners"].extend(scripts_blk)
            packerfile["provisioners"].extend(sync)
            with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", delete=False
            ) as new_packerfile:
                new_packerfile.write(json.dumps(packerfile, indent=2))
                new_packerfile.flush()

                return self._replace(packerfile=os.path.abspath(new_packerfile.name))

    def install_plugins(self, name: str) -> List[str]:
        return [self.packer_path, "plugins", "install"] + [name]

    def cli(self) -> List[str]:
        """Interpolate the class into a packer invocation."""
        vars = (
            ["-var " + '"' + k + "=" + v + '"' for k, v in self.cli_vars.items()]
            if self.cli_vars
            else []
        ) + ["-var " + '"' + "name" + "=" + self.name + '"']

        match self.variant:
            case Build():
                cmd = (
                    [
                        self.packer_path,
                        "build",
                        "-force" if self.overwrite else None,
                        "-var-file=" + self.var_file if self.var_file else None,
                        (
                            "-var "
                            + self.sha256_var_name
                            + "="
                            + sha256(self.iso_img_loc)
                            if self.sha256_var_name
                            else None
                        ),
                    ]
                    + vars
                    + [self.packerfile]
                )
                return list(filter(lambda x: x is not None, cmd))
            case InsertFile():
                cmd = (
                    [
                        self.packer_path,
                        "build",
                        "-force" if self.overwrite else None,
                        (
                            "-var "
                            + self.sha256_var_name
                            + "="
                            + sha256(self.iso_img_loc)
                            if self.sha256_var_name
                            else None
                        ),
                    ]
                    + vars
                    + [self.packerfile]
                )
                return list(filter(lambda x: x is not None, cmd))
            case RunScripts():
                cmd = (
                    [
                        self.packer_path,
                        "build",
                        "-force " if self.overwrite else None,
                        (
                            "-var "
                            + self.sha256_var_name
                            + "="
                            + sha256(self.iso_img_loc)
                            if self.sha256_var_name
                            else None
                        ),
                    ]
                    + vars
                    + [self.packerfile]
                )
                return list(filter(lambda x: x is not None, cmd))


def deal_with_existing_out_dir(config: Config):
    """Deal with existing output directory by rm'ing it, if empty."""
    if os.path.exists(config.out_dir):
        log.debug("output dir exists, removing contents of " + config.out_dir)
        f_contents = os.listdir(config.out_dir)
        if len(f_contents) == 0:
            log.debug("folder empty, removing folder")
            os.rmdir(config.out_dir)
        else:
            if config.overwrite:
                for root, dirs, files in os.walk(config.out_dir):
                    print(root)
                    print(dirs)
                    print(files)
                    raise NotImplementedError("with files existing is not implemented")

            else:
                raise NotImplementedError("not implemented for non-overwrite")
                pass  # some clever sha thing? or just never run packer


def find_system_qemu(tgt_arch):
    """Which's to try to find qemu."""
    qemu_search = "qemu-system-" + tgt_arch
    qemu = shutil.which(qemu_search)
    if qemu is None:
        system = platform.system().lower()
        print(system)
        if system == "linux":
            qemu = shutil.which(qemu_search, path="/bin:/usr/bin:/usr/local/bin")
        elif system == "macos" or system == "darwin":
            qemu = shutil.which(
                qemu_search, path="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin"
            )
    if qemu is None:
        raise RuntimeError("cannot find " + qemu_search)
    return qemu


def invoke_packer(config, qemu_path, additional_plugins=None):
    log.debug("calling: " + str(" ".join(config.cli())))
    path = os.environ.get("PATH")

    if path is None:
        path = qemu_path
    else:
        path = path + ":" + qemu_path

    env = dict(copy.deepcopy(os.environ))
    env.update({"PATH": path, "PWD": os.getcwd()})
    log.debug("with PATH: " + path)
    log.debug("with ENV: " + str(env))
    for plugin_name in additional_plugins:
        sp.run(
            " ".join(config.install_plugins(plugin_name)),
            shell=True,
            env=env,
            cwd=os.getcwd(),
        )
    proc = sp.run(" ".join(config.cli()), shell=True, env=env, cwd=os.getcwd())
    return proc


def cli():
    parser = argparse.ArgumentParser()

    # Create a subparser for separate commands
    subparsers = parser.add_subparsers(dest="command")

    # Build command
    build_parser = subparsers.add_parser("build")
    build_parser.set_defaults(func=build)
    # Add a required argument for the config file
    build_parser.add_argument(
        "--config-file", type=str, required=True, help="Path to the configuration file."
    )

    # Insert file command
    insert_file_parser = subparsers.add_parser("insert_file")
    # Add a required argument for the config file
    insert_file_parser.add_argument(
        "--config-file", type=str, required=True, help="Path to the configuration file."
    )
    insert_file_parser.add_argument(
        "--files",
        type=str,
        required=True,
        help="file location of path mapping of file: location to insert.",
    )
    insert_file_parser.set_defaults(func=insert_file)

    # Run script command
    run_script_parser = subparsers.add_parser("run_script")
    # Add a required argument for the config file
    run_script_parser.add_argument(
        "--config-file", type=str, required=True, help="Path to the configuration file."
    )
    run_script_parser.add_argument(
        "--scripts", nargs="+", type=str, required=True, help="List of scripts to run."
    )
    run_script_parser.set_defaults(func=run_script)

    # Parse arguments and call the appropriate function
    args = parser.parse_args()
    args.func(args)


def build(args):
    config = Config.from_path(args.config_file, Build())
    qemu_name = find_system_qemu(config.architecture)
    qemu_path = os.path.dirname(qemu_name)
    deal_with_existing_out_dir(config)
    packer = invoke_packer(config, qemu_path, ["github.com/hashicorp/qemu"])
    sys.exit(packer.returncode)


def insert_file(args):
    config = Config.from_path(args.config_file, InsertFile())
    qemu_name = find_system_qemu(config.architecture)
    qemu_path = os.path.dirname(qemu_name)
    deal_with_existing_out_dir(config)
    config = config.splice_files_to_transfer(args.files)
    print(config.cli())
    packer = invoke_packer(config, qemu_path, ["github.com/hashicorp/qemu"])
    sys.exit(packer.returncode)


def run_script(args):
    config = Config.from_path(args.config_file, RunScripts())
    qemu_name = find_system_qemu(config.architecture)
    qemu_path = os.path.dirname(qemu_name)
    deal_with_existing_out_dir(config)
    config = config.splice_scripts_to_run(args.scripts)
    print(config.cli())
    packer = invoke_packer(config, qemu_path, ["github.com/hashicorp/qemu"])
    sys.exit(packer.returncode)


if __name__ == "__main__":
    log.basicConfig(level=log.DEBUG)
    cli()
