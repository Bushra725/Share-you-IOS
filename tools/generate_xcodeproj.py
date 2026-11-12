#!/usr/bin/env python3
"""
Generates ShareYou.xcodeproj (Xcode 16+ format, objectVersion 77).

The ShareYou/ folder is a *synchronized* group: every file you add to it in Finder or Xcode
is picked up automatically, so you normally never need to run this again.
Re-run it only if you want to reset the project file:  python3 tools/generate_xcodeproj.py
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJ = os.path.join(ROOT, "ShareYou.xcodeproj")


def oid(name: str) -> str:
    return hashlib.md5(name.encode()).hexdigest().upper()[:24]


PACKAGES = [
    # (key, url, minimum version, [products])
    ("firebase", "https://github.com/firebase/firebase-ios-sdk.git", "12.0.0",
     ["FirebaseAnalytics", "FirebaseCrashlytics", "FirebaseMessaging", "FirebaseRemoteConfig",
      "FirebaseAuth", "FirebaseFirestore", "FirebaseAppCheck"]),
    ("googlesignin", "https://github.com/google/GoogleSignIn-iOS.git", "8.0.0", ["GoogleSignIn"]),
    ("gma", "https://github.com/googleads/swift-package-manager-google-mobile-ads.git", "12.0.0", ["GoogleMobileAds"]),
    ("ump", "https://github.com/googleads/swift-package-manager-google-user-messaging-platform.git", "3.0.0",
     ["GoogleUserMessagingPlatform"]),
]

CONFIG_FILES = ["Base.xcconfig", "Debug.xcconfig", "Release.xcconfig", "Secrets.example.xcconfig",
                "Info.plist", "ShareYou.entitlements"]

CRASHLYTICS_INPUTS = [
    "${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}",
    "${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${PRODUCT_NAME}",
    "${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Info.plist",
    "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/GoogleService-Info.plist",
    "$(TARGET_BUILD_DIR)/$(EXECUTABLE_PATH)",
    "${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${PRODUCT_NAME}.debug.dylib",
]


def q(s: str) -> str:
    """Quote a pbxproj string value when needed."""
    safe = all(c.isalnum() or c in "._/$" for c in s) and s != ""
    if safe:
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def main():
    os.makedirs(PROJ, exist_ok=True)
    P = oid("project")
    T = oid("target.ShareYou")
    MAIN = oid("group.main")
    PRODUCTS = oid("group.products")
    CONFIG_GROUP = oid("group.config")
    SYNC = oid("sync.ShareYou")
    APP = oid("product.app")
    SRC_PHASE, FW_PHASE, RES_PHASE, SCRIPT_PHASE = (oid(x) for x in ("phase.src", "phase.fw", "phase.res", "phase.crashlytics"))
    PCL, TCL = oid("configlist.project"), oid("configlist.target")
    PDEBUG, PRELEASE, TDEBUG, TRELEASE = (oid(x) for x in ("p.debug", "p.release", "t.debug", "t.release"))

    files = {name: oid("file." + name) for name in CONFIG_FILES}
    o = []

    o.append("/* Begin PBXBuildFile section */")
    for key, _, _, products in PACKAGES:
        for p in products:
            o.append(f"\t\t{oid('bf.' + p)} /* {p} in Frameworks */ = {{isa = PBXBuildFile; productRef = {oid('dep.' + p)} /* {p} */; }};")
    o.append("/* End PBXBuildFile section */\n")

    o.append("/* Begin PBXFileReference section */")
    o.append(f"\t\t{APP} /* ShareYou.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ShareYou.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    for name, ident in files.items():
        ftype = {"xcconfig": "text.xcconfig", "plist": "text.plist.xml", "entitlements": "text.plist.entitlements"}[name.rsplit(".", 1)[1]]
        o.append(f"\t\t{ident} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = {q(name)}; sourceTree = \"<group>\"; }};")
    o.append("/* End PBXFileReference section */\n")

    o.append("/* Begin PBXFileSystemSynchronizedRootGroup section */")
    o.append(f"\t\t{SYNC} /* ShareYou */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = ShareYou; sourceTree = \"<group>\"; }};")
    o.append("/* End PBXFileSystemSynchronizedRootGroup section */\n")

    o.append("/* Begin PBXFrameworksBuildPhase section */")
    fw = "\n".join(f"\t\t\t\t{oid('bf.' + p)} /* {p} in Frameworks */," for _, _, _, ps in PACKAGES for p in ps)
    o.append(f"\t\t{FW_PHASE} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{fw}\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
    o.append("/* End PBXFrameworksBuildPhase section */\n")

    o.append("/* Begin PBXGroup section */")
    cfg_children = "\n".join(f"\t\t\t\t{ident} /* {name} */," for name, ident in files.items())
    o.append(f"\t\t{MAIN} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{SYNC} /* ShareYou */,\n\t\t\t\t{CONFIG_GROUP} /* Config */,\n\t\t\t\t{PRODUCTS} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
    o.append(f"\t\t{CONFIG_GROUP} /* Config */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{cfg_children}\n\t\t\t);\n\t\t\tpath = Config;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
    o.append(f"\t\t{PRODUCTS} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{APP} /* ShareYou.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
    o.append("/* End PBXGroup section */\n")

    o.append("/* Begin PBXNativeTarget section */")
    deps = "\n".join(f"\t\t\t\t{oid('dep.' + p)} /* {p} */," for _, _, _, ps in PACKAGES for p in ps)
    o.append(f"""\t\t{T} /* ShareYou */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {TCL} /* Build configuration list for PBXNativeTarget "ShareYou" */;
\t\t\tbuildPhases = (
\t\t\t\t{SRC_PHASE} /* Sources */,
\t\t\t\t{FW_PHASE} /* Frameworks */,
\t\t\t\t{RES_PHASE} /* Resources */,
\t\t\t\t{SCRIPT_PHASE} /* Upload dSYMs to Crashlytics */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{SYNC} /* ShareYou */,
\t\t\t);
\t\t\tname = ShareYou;
\t\t\tpackageProductDependencies = (
{deps}
\t\t\t);
\t\t\tproductName = ShareYou;
\t\t\tproductReference = {APP} /* ShareYou.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};""")
    o.append("/* End PBXNativeTarget section */\n")

    o.append("/* Begin PBXProject section */")
    pkgs = "\n".join(f"\t\t\t\t{oid('pkg.' + k)} /* XCRemoteSwiftPackageReference \"{u.rsplit('/', 1)[1][:-4]}\" */," for k, u, _, _ in PACKAGES)
    o.append(f"""\t\t{P} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1640;
\t\t\t\tLastUpgradeCheck = 1640;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{T} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 16.4;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {PCL} /* Build configuration list for PBXProject "ShareYou" */;
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t\tar,
\t\t\t\tes,
\t\t\t\tfr,
\t\t\t\thi,
\t\t\t\tid,
\t\t\t\tpt,
\t\t\t\ttr,
\t\t\t\tur,
\t\t\t);
\t\t\tmainGroup = {MAIN};
\t\t\tminimizedProjectReferenceProxies = 1;
\t\t\tpackageReferences = (
{pkgs}
\t\t\t);
\t\t\tpreferredProjectObjectVersion = 77;
\t\t\tproductRefGroup = {PRODUCTS} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{T} /* ShareYou */,
\t\t\t);
\t\t}};""")
    o.append("/* End PBXProject section */\n")

    o.append("/* Begin PBXResourcesBuildPhase section */")
    o.append(f"\t\t{RES_PHASE} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
    o.append("/* End PBXResourcesBuildPhase section */\n")

    o.append("/* Begin PBXShellScriptBuildPhase section */")
    inputs = "\n".join(f"\t\t\t\t{q(p)}," for p in CRASHLYTICS_INPUTS)
    script = '"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"\n'
    o.append(f"""\t\t{SCRIPT_PHASE} /* Upload dSYMs to Crashlytics */ = {{
\t\t\tisa = PBXShellScriptBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\tinputFileListPaths = (
\t\t\t);
\t\t\tinputPaths = (
{inputs}
\t\t\t);
\t\t\tname = "Upload dSYMs to Crashlytics";
\t\t\toutputFileListPaths = (
\t\t\t);
\t\t\toutputPaths = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t\tshellPath = /bin/sh;
\t\t\tshellScript = {q(script)};
\t\t\tshowEnvVarsInLog = 0;
\t\t}};""")
    o.append("/* End PBXShellScriptBuildPhase section */\n")

    o.append("/* Begin PBXSourcesBuildPhase section */")
    o.append(f"\t\t{SRC_PHASE} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
    o.append("/* End PBXSourcesBuildPhase section */\n")

    o.append("/* Begin XCBuildConfiguration section */")
    common_project = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = NO;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tLOCALIZATION_PREFERS_STRING_CATALOGS = YES;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;"""
    for ident, name, xc in ((PDEBUG, "Debug", "Debug"), (PRELEASE, "Release", "Release")):
        o.append(f"""\t\t{ident} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbaseConfigurationReference = {files[xc + '.xcconfig']} /* {xc}.xcconfig */;
\t\t\tbuildSettings = {{
{common_project}
\t\t\t}};
\t\t\tname = {name};
\t\t}};""")
    for ident, name, xc in ((TDEBUG, "Debug", "Debug"), (TRELEASE, "Release", "Release")):
        o.append(f"""\t\t{ident} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbaseConfigurationReference = {files[xc + '.xcconfig']} /* {xc}.xcconfig */;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t}};
\t\t\tname = {name};
\t\t}};""")
    o.append("/* End XCBuildConfiguration section */\n")

    o.append("/* Begin XCConfigurationList section */")
    for ident, label, a, b in ((PCL, 'PBXProject "ShareYou"', PDEBUG, PRELEASE), (TCL, 'PBXNativeTarget "ShareYou"', TDEBUG, TRELEASE)):
        o.append(f"""\t\t{ident} /* Build configuration list for {label} */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{a} /* Debug */,
\t\t\t\t{b} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};""")
    o.append("/* End XCConfigurationList section */\n")

    o.append("/* Begin XCRemoteSwiftPackageReference section */")
    for k, url, ver, _ in PACKAGES:
        o.append(f"""\t\t{oid('pkg.' + k)} /* XCRemoteSwiftPackageReference "{url.rsplit('/', 1)[1][:-4]}" */ = {{
\t\t\tisa = XCRemoteSwiftPackageReference;
\t\t\trepositoryURL = "{url}";
\t\t\trequirement = {{
\t\t\t\tkind = upToNextMajorVersion;
\t\t\t\tminimumVersion = {ver};
\t\t\t}};
\t\t}};""")
    o.append("/* End XCRemoteSwiftPackageReference section */\n")

    o.append("/* Begin XCSwiftPackageProductDependency section */")
    for k, url, _, products in PACKAGES:
        for p in products:
            o.append(f"""\t\t{oid('dep.' + p)} /* {p} */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {oid('pkg.' + k)} /* XCRemoteSwiftPackageReference "{url.rsplit('/', 1)[1][:-4]}" */;
\t\t\tproductName = {p};
\t\t}};""")
    o.append("/* End XCSwiftPackageProductDependency section */")

    body = "\n".join(o)
    text = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 77;
\tobjects = {{

{body}
\t}};
\trootObject = {P} /* Project object */;
}}
"""
    with open(os.path.join(PROJ, "project.pbxproj"), "w") as f:
        f.write(text)

    # Shared scheme: Run = Debug, Archive = Release.
    scheme_dir = os.path.join(PROJ, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    ref = f"""<BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{T}"
               BuildableName = "ShareYou.app"
               BlueprintName = "ShareYou"
               ReferencedContainer = "container:ShareYou.xcodeproj">
            </BuildableReference>"""
    scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1640"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
      <CommandLineArguments>
         <CommandLineArgument
            argument = "-FIRDebugEnabled"
            isEnabled = "NO">
         </CommandLineArgument>
      </CommandLineArguments>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    with open(os.path.join(scheme_dir, "ShareYou.xcscheme"), "w") as f:
        f.write(scheme)
    print("Wrote", PROJ)


if __name__ == "__main__":
    main()
