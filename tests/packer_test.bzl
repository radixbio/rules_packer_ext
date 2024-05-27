load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@com_github_rules_packer//:packer.bzl", "PackerCommonInfo", "packer_qemu")

def _packer_qemu_simple_test_impl(ctx):
    env = analysistest.begin(ctx)
    target_under_test = analysistest.target_under_test(env)
    substitutions = target_under_test[PackerCommonInfo].substitutions
    asserts.false(env, "file.txt" == paths.basename("$(location file.txt)"))
    asserts.equals(env, "file.txt", paths.basename(substitutions["{single_file}"]))
    return analysistest.end(env)

packer_qemu_simple_test = analysistest.make(_packer_qemu_simple_test_impl)

def _test_packer_qemu():
    packer_qemu(
        name = "packer_some_name",
        tags = ["manual"],
        packerfile = "packerfile.json",
        input_img = "image.iso",
        substitutions = {
            "{single_file}": "$(location file.txt)",
            "{list_file}": ",".join(["$(location " + x + ")" for x in [
                "file.txt",
                "file2.txt",
            ]]),
        },
        deps = ["file.txt", "file2.txt"],
    )
    packer_qemu_simple_test(
        name = "packer_qemu_simple_test",
        target_under_test = ":packer_some_name",
    )

def packer_test_suite(name):
    _test_packer_qemu()
    native.test_suite(
        name = name,
        tests = [":packer_qemu_simple_test"],
    )
