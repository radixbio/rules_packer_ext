load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//:packer.bzl", "img_path_subst")

def _img_path_subst_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "hello",
        img_path_subst("hello", "nothing", "here"),
    )
    asserts.equals(
        env,
        "replace word",
        img_path_subst("replace this", "this", "word"),
    )
    asserts.equals(
        env,
        "replace word word",
        img_path_subst("replace this this", "this", "word"),
    )
    return unittest.end(env)

img_path_subst_test = unittest.make(_img_path_subst_test_impl)

def packer_test_suite(name):
    unittest.suite(name, img_path_subst_test)
