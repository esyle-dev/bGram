load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "PostShareImageScreen",
    module_name = "PostShareImageScreen",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/TelegramUIPreferences",
        "//submodules/TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/ComponentFlow",
        "//submodules/Components/ViewControllerComponent",
        "//submodules/Components/MultilineTextComponent",
        "//submodules/Components/BundleIconComponent",
        "//submodules/Components/SheetComponent",
        "//submodules/TelegramPresentationData",
        "//submodules/AccountContext",
        "//submodules/WallpaperBackgroundNode",
        "//submodules/InvisibleInkDustNode",
        "//submodules/TelegramUI/Components/LottieComponent",
        "//submodules/TelegramUI/Components/ButtonComponent",
        "//submodules/TelegramUI/Components/GlassBarButtonComponent",
        "//submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode",
    ],
    visibility = [
        "//visibility:public",
    ],
)
