load("@aspect_bazel_lib//lib:expand_make_vars.bzl", "expand_locations")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@com_github_rules_packer_config//:config.bzl", "PACKER_ARCH", "PACKER_BIN_NAME", "PACKER_DEBUG", "PACKER_DISPLAY", "PACKER_GLOBAL_SUBS", "PACKER_OS", "PACKER_SHAS", "PACKER_VERSION")

def _get_iso_loc_from_tgt(tgt):
    # this is passed a bazel target for input_img
    # so let's get the actual file reference to the input_img
    # first we do some validation to say that iff it has multiple files, we fail
    flisting = tgt.files.to_list()
    if len(flisting) != 1:
        fail("input image should not have more than one file. It contains " + flisting)

    path = flisting[0]

    # it may be a directory with the directory named the same as the file
    if path.is_directory:
        path = paths.join(path.path, path.basename)
    else:
        # but we don't need a file object, we need a full (relative) path
        path = path.path

    return path

def _subst(ctx, input_substitutions, add_subst = False):
    # this method deals with a substitutions dict that will eventually be passed into
    # ctx.actions.expand_template

    # get the relative path to the input disk image (or iso)
    path = _get_iso_loc_from_tgt(ctx.attr.input_img)

    # and declare the substitution for packer
    # the default here is "file://{{ env `PWD` }}/{input_img}"
    # so we'd like to turn that into something like file:///monorepo/bazel-out/crap/external/ubuntu/ubuntu.iso
    # so it can be substituted later
    img_path = ctx.attr.input_img_fmtstring.replace("{input_img}", path)

    # if any of the values in the declared substitutions have a location directive, we'd like to expand that
    # given the location of anything in deps, or the input_img, those are valid things to expand the $(location)
    # syntax on
    # the value substitution can also contain a {input_img} substring
    # to be noted, this is *different* from the substitution that may be used in the var file
    # NOTE: i'm not sure this second layer of substitution is required
    out_dict = {
        k: expand_locations(
            ctx,
            v,
            ctx.attr.deps + [ctx.attr.input_img],
        )
            .replace(ctx.attr.input_img_subs_key, img_path)
        for k, v in input_substitutions.items()
    }

    if add_subst:
        out_dict[ctx.attr.input_img_subs_key] = img_path
    return out_dict

def _write_var_file(ctx, varfile, substitutions, suffix = "_"):
    var_file = None
    if varfile:
        var_file = ctx.actions.declare_file(ctx.attr.name + suffix + ".var")
        ctx.actions.expand_template(
            template = varfile,
            output = var_file,
            substitutions = substitutions,
        )
    return var_file

def _write_config_json(ctx, path, cli_vars, packerfile, var_file, env, out):
    pyscript_content = """{{
      "name": "{name}",
      "architecture": "{architecture}",
      "overwrite": {overwrite},
      "packerfile": "{packerfile}",
      "out_dir": "{out_dir}",
      "var_file": "{var_file}",
      "cli_vars": {cli_vars},
      "packer_path": "{packer_path}",
      "iso_var_name": "{iso_var_name}",
      "sha256_var_name": "{sha256_var_name}",
      "iso_img_loc": "{iso_img_loc}",
      "env": {env}
    }}""".format(
        name = str(ctx.attr.name),
        architecture = str(ctx.attr.architecture),
        overwrite = str(ctx.attr.overwrite).lower(),  # json boolean
        packerfile = packerfile.path,
        out_dir = out.path,
        cli_vars = cli_vars if cli_vars else "null",
        var_file = var_file.path if var_file else "null",
        packer_path = ctx.file._packer.path,
        iso_var_name = ctx.attr.iso_var_name if ctx.attr.iso_var_name else "null",
        sha256_var_name = ctx.attr.sha256_var_name if ctx.attr.sha256_var_name else "null",
        iso_img_loc = path,
        env = str(env),
    )
    pyscript_input = ctx.actions.declare_file("run-" + ctx.attr.name + ".input.json")

    ctx.actions.write(
        output = pyscript_input,
        content = pyscript_content,
    )
    return pyscript_input

def _write_pkr_file(ctx, template, substitutions):
    packerfile = ctx.actions.declare_file(ctx.attr.name + ".pkr")
    ctx.actions.expand_template(
        template = template,
        output = packerfile,
        substitutions = substitutions,
    )
    return packerfile

PackerCommonInfo = provider(fields = ["substitutions", "env_items"])

def _common_init(ctx, pkrfile, varfile, vars):
    # Declare our output directory (this may not be a thing for all builders, but it is for QEMU)
    out = ctx.actions.declare_directory(ctx.attr.name)

    # this may be a file (http_file) or a directory (deps on another packer_qemu rule)
    path = _get_iso_loc_from_tgt(ctx.attr.input_img)

    # there are two things worth substituting, the substitutions themselves
    # so they can reference dependencies using $(location //name/of:dep)
    # and the image path substitution
    # so an environment variable (or more commonly a substitution) can reference the input image path like
    # substitutions = {
    #     "{iso}": "{input_img}"
    # }
    # declare our substitutions, merge with the global map, and splice in output / $(locations)
    subst_items = dict(ctx.attr.substitutions) if ctx.attr.substitutions else {}
    subst_items.update(PACKER_GLOBAL_SUBS)
    if subst_items.get("{output}") == "$(location output)":
        subst_items.update({"{output}": out.path})
    if subst_items.get("{name}") == None:
        subst_items.update({"{name}": ctx.attr.name})
    substitutions = _subst(ctx, subst_items, True)

    # declare our environent, splice in output / $(locations)
    env_items = dict(ctx.attr.env) if ctx.attr.env else {}

    #env_items.update(PACKER_GLOBAL_SUBS)
    if env_items.get("{output}") == "$(location output)":
        env_items.update({"{output}": out.path})
    env = _subst(ctx, env_items)

    # packer has a debug thing ...
    if ctx.attr.debug:
        env.update({"PACKER_LOG": "1"})

    # pull the $DISPLAY env var so gtk can do thing
    if PACKER_DISPLAY != "":
        env.update({"DISPLAY": PACKER_DISPLAY})

    # and support for var files with $(location)
    var_file = _write_var_file(ctx, varfile, substitutions)

    # pack the vars command line arguments, substituting $(location) and {input_img}
    cli_vars = _subst(ctx, vars if vars else {})

    # as well as the actual packerfile with $(location)
    packerfile = _write_pkr_file(ctx, pkrfile, substitutions)

    # finally, we generate the input configuration file for the python script
    pyscript_input = _write_config_json(ctx, path, cli_vars, packerfile, var_file, env, out)

    env.update({"HOME": "."})

    return pyscript_input, packerfile, var_file, env, out, PackerCommonInfo(
        substitutions = substitutions,
        env_items = env_items,
    )

def _packer_qemu_impl(ctx):
    py = ctx.toolchains["@bazel_tools//tools/python:toolchain_type"].py3_runtime.interpreter

    pyscript_input, packerfile, var_file, env, out, info = _common_init(
        ctx,
        ctx.file.packerfile,
        ctx.file.var_file,
        ctx.attr.vars,
    )

    # and execute it
    ctx.actions.run(
        executable = py.path,
        arguments = [
            ctx.executable._deployment_script.path,
            "build",
            "--config-file",
            pyscript_input.path,
        ],
        env = env,
        inputs = [x for x in [packerfile, var_file] if x != None] + ctx.files.deps + [pyscript_input] + ctx.attr.input_img.files.to_list(),  # Look, i know it's stupid
        outputs = [out],
        mnemonic = "PackerBuild",
        tools = [ctx.file._packer, ctx.executable._deployment_script, py] + ctx.attr._py.files.to_list(),
    )

    return [DefaultInfo(files = depset([out])), info]

packer_qemu = rule(
    implementation = _packer_qemu_impl,
    toolchains = ["@bazel_tools//tools/python:toolchain_type"],
    attrs = {
        "architecture": attr.string(
            default = "x86_64",
        ),
        "overwrite": attr.bool(
            default = False,
        ),
        "packerfile": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "var_file": attr.label(
            allow_single_file = True,
        ),
        "input_img": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "input_img_fmtstring": attr.string(
            default = "file://{{ env `PWD` }}/{input_img}",
        ),
        "input_img_subs_key": attr.string(
            default = "{iso}",
        ),
        "iso_var_name": attr.string(
            default = "iso_urls",
        ),
        "sha256_var_name": attr.string(
            default = "iso_checksum",
        ),
        "substitutions": attr.string_dict(),  # NOTE: Substitutes in the templates
        "vars": attr.string_dict(),  # NOTE: passed as CLI args
        "env": attr.string_dict(),  # NOTE: passed to the packer command
        "deps": attr.label_list(
            allow_files = True,
        ),
        "_deployment_script": attr.label(
            allow_single_file = True,
            default = "//:packer.py",  # NOTE: this script is used to handle the "overwrite" flag properly
            executable = True,
            cfg = "exec",
        ),
        "debug": attr.bool(
            default = PACKER_DEBUG,
        ),
        "_packer": attr.label(
            allow_single_file = True,
            default = "@packer//:" + PACKER_BIN_NAME,  # TODO: Toolchain here?
        ),
        "_py": attr.label(
            default = "@rules_python//python:current_py_toolchain",
        ),
    },
)

def _packer_insert_file(ctx):
    py = ctx.toolchains["@bazel_tools//tools/python:toolchain_type"].py3_runtime.interpreter

    pyscript_input, packerfile, var_file, env, out, info = _common_init(
        ctx,
        ctx.file._packerfile,
        None,
        None,
    )

    paths_mapping_file = ctx.actions.declare_file(ctx.attr.name + "_path_mapping_.json")
    expanded_path_mappings = []
    for tgt, v in ctx.attr.paths.items():
        for k in tgt.files.to_list():
            expanded_path_mappings.append((k.path, v))
    expanded_path_mappings = dict(expanded_path_mappings)
    ctx.actions.write(
        output = paths_mapping_file,
        content = str(expanded_path_mappings),
    )

    # and execute it
    ctx.actions.run(
        executable = py.path,
        arguments = [
            ctx.executable._deployment_script.path,
            "insert_file",
            "--config-file",
            pyscript_input.path,
            "--files",
            paths_mapping_file.path,
        ],
        env = env,
        inputs = [x for x in [packerfile, var_file] if x != None] +
                 ctx.files.deps +
                 [pyscript_input, paths_mapping_file] +
                 ctx.attr.input_img.files.to_list(),  # Look, i know it's stupid
        outputs = [out],
        mnemonic = "Packer",
        tools = [ctx.file._packer, ctx.executable._deployment_script, py] + ctx.attr._py.files.to_list(),
    )

    return [DefaultInfo(files = depset([out]))]

packer_insert_file = rule(
    implementation = _packer_insert_file,
    toolchains = ["@bazel_tools//tools/python:toolchain_type"],
    attrs = {
        "architecture": attr.string(
            default = "x86_64",
        ),
        "overwrite": attr.bool(
            default = False,
        ),
        "input_img": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "input_img_fmtstring": attr.string(
            default = "file://{{ env `PWD` }}/{input_img}",
        ),
        "input_img_subs_key": attr.string(
            default = "{iso}",
        ),
        "iso_var_name": attr.string(
            default = "iso_urls",
        ),
        "sha256_var_name": attr.string(
            default = "iso_checksum",
        ),
        "substitutions": attr.string_dict(),  # NOTE: Substitutes in the templates
        "env": attr.string_dict(),  # NOTE: passed to the packer command
        "paths": attr.label_keyed_string_dict(
            mandatory = True,
        ),
        "deps": attr.label_list(
            allow_files = True,
        ),
        "_deployment_script": attr.label(
            allow_single_file = True,
            default = "//:packer.py",  # NOTE: this script is used to handle the "overwrite" flag properly
            executable = True,
            cfg = "exec",
        ),
        "debug": attr.bool(
            default = PACKER_DEBUG,
        ),
        "_packerfile": attr.label(
            allow_single_file = True,
            default = ":provision.json",
        ),
        "_packer": attr.label(
            allow_single_file = True,
            default = "@packer//:" + PACKER_BIN_NAME,  # TODO: Toolchain here?
        ),
        "_py": attr.label(
            default = "@rules_python//python:current_py_toolchain",
        ),
    },
)

def _packer_run_scripts(ctx):
    py = ctx.toolchains["@bazel_tools//tools/python:toolchain_type"].py3_runtime.interpreter

    pyscript_input, packerfile, var_file, env, out, info = _common_init(
        ctx,
        ctx.file._packerfile,
        None,
        None,
    )

    scripts = []
    for tgt in ctx.attr.scripts:
        for k in tgt.files.to_list():
            scripts.append(k)

    # and execute it
    ctx.actions.run(
        executable = py.path,
        arguments = [
            ctx.executable._deployment_script.path,
            "run_script",
            "--config-file",
            pyscript_input.path,
            "--scripts",
        ] + [k.path for k in scripts],
        env = env,
        inputs = [x for x in [packerfile, var_file] if x != None] +
                 ctx.files.deps +
                 [pyscript_input] +
                 scripts +
                 ctx.attr.input_img.files.to_list(),  # Look, i know it's stupid
        outputs = [out],
        mnemonic = "Packer",
        tools = [ctx.file._packer, ctx.executable._deployment_script, py] + ctx.attr._py.files.to_list(),
    )

    return [DefaultInfo(files = depset([out]))]

packer_run_scripts = rule(
    implementation = _packer_run_scripts,
    toolchains = ["@bazel_tools//tools/python:toolchain_type"],
    attrs = {
        "architecture": attr.string(
            default = "x86_64",
        ),
        "overwrite": attr.bool(
            default = False,
        ),
        "input_img": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "input_img_fmtstring": attr.string(
            default = "file://{{ env `PWD` }}/{input_img}",
        ),
        "input_img_subs_key": attr.string(
            default = "{iso}",
        ),
        "iso_var_name": attr.string(
            default = "iso_urls",
        ),
        "sha256_var_name": attr.string(
            default = "iso_checksum",
        ),
        "substitutions": attr.string_dict(),  # NOTE: Substitutes in the templates
        "env": attr.string_dict(),  # NOTE: passed to the packer command
        "scripts": attr.label_list(
            allow_files = True,
        ),
        "deps": attr.label_list(
            allow_files = True,
        ),
        "_deployment_script": attr.label(
            allow_single_file = True,
            default = "//:packer.py",  # NOTE: this script is used to handle the "overwrite" flag properly
            executable = True,
            cfg = "exec",
        ),
        "debug": attr.bool(
            default = PACKER_DEBUG,
        ),
        "_packerfile": attr.label(
            allow_single_file = True,
            default = ":provision.json",
        ),
        "_packer": attr.label(
            allow_single_file = True,
            default = "@packer//:" + PACKER_BIN_NAME,  # TODO: Toolchain here?
        ),
        "_py": attr.label(
            default = "@rules_python//python:current_py_toolchain",
        ),
    },
)
