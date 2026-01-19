import os
import uuid

def generate_uuid():
    return str(uuid.uuid4()).replace('-', '')[:24].upper()

PROJECT_NAME = "ClipKitty"
TARGET_NAME = "ClipKittyUITests"
BUNDLE_ID = "com.clipkitty.UITests"
SOURCE_FILE = "Tests/UITests/ClipKittyUITests.swift"

# UUIDs
PBX_PROJECT_ID = generate_uuid()
PBX_GROUP_MAIN_ID = generate_uuid()
PBX_GROUP_TESTS_ID = generate_uuid()
PBX_FILE_SOURCE_ID = generate_uuid()
PBX_BUILD_FILE_ID = generate_uuid()
PBX_NATIVE_TARGET_ID = generate_uuid()
PBX_CONFIG_LIST_PROJECT_ID = generate_uuid()
PBX_CONFIG_LIST_TARGET_ID = generate_uuid()
PBX_CONFIG_DEBUG_PROJ_ID = generate_uuid()
PBX_CONFIG_RELEASE_PROJ_ID = generate_uuid()
PBX_CONFIG_DEBUG_TARGET_ID = generate_uuid()
PBX_CONFIG_RELEASE_TARGET_ID = generate_uuid()
PBX_SOURCES_BUILD_PHASE_ID = generate_uuid()
PBX_FRAMEWORKS_BUILD_PHASE_ID = generate_uuid()
PBX_RESOURCES_BUILD_PHASE_ID = generate_uuid()
PBX_PRODUCT_REF_ID = generate_uuid()
PBX_GROUP_PRODUCTS_ID = generate_uuid()

CONTENT = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 55;
	objects = {{

/* Begin PBXBuildFile section */
		{PBX_BUILD_FILE_ID} /* {os.path.basename(SOURCE_FILE)} in Sources */ = {{isa = PBXBuildFile; fileRef = {PBX_FILE_SOURCE_ID} /* {os.path.basename(SOURCE_FILE)} */; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		{PBX_FILE_SOURCE_ID} /* {os.path.basename(SOURCE_FILE)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{SOURCE_FILE}"; sourceTree = "<group>"; }};
		{PBX_PRODUCT_REF_ID} /* {TARGET_NAME}.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = "{TARGET_NAME}.xctest"; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXGroup section */
		{PBX_GROUP_MAIN_ID} = {{
			isa = PBXGroup;
			children = (
				{PBX_GROUP_TESTS_ID} /* Tests */,
				{PBX_GROUP_PRODUCTS_ID} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{PBX_GROUP_PRODUCTS_ID} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{PBX_PRODUCT_REF_ID} /* {TARGET_NAME}.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
		{PBX_GROUP_TESTS_ID} /* Tests */ = {{
			isa = PBXGroup;
			children = (
				{PBX_FILE_SOURCE_ID} /* {os.path.basename(SOURCE_FILE)} */,
			);
			path = ".";
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{PBX_NATIVE_TARGET_ID} /* {TARGET_NAME} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {PBX_CONFIG_LIST_TARGET_ID} /* Build configuration list for PBXNativeTarget "{TARGET_NAME}" */;
			buildPhases = (
				{PBX_SOURCES_BUILD_PHASE_ID} /* Sources */,
				{PBX_FRAMEWORKS_BUILD_PHASE_ID} /* Frameworks */,
				{PBX_RESOURCES_BUILD_PHASE_ID} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = "{TARGET_NAME}";
			productName = "{TARGET_NAME}";
			productReference = {PBX_PRODUCT_REF_ID} /* {TARGET_NAME}.xctest */;
			productType = "com.apple.product-type.bundle.ui-testing";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{PBX_PROJECT_ID} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				LastUpgradeCheck = 1500;
				TargetAttributes = {{
					{PBX_NATIVE_TARGET_ID} = {{
						CreatedOnToolsVersion = 15.0;
						TestTargetID = {PBX_NATIVE_TARGET_ID};
					}};
				}};
			}};
			buildConfigurationList = {PBX_CONFIG_LIST_PROJECT_ID} /* Build configuration list for PBXProject "{PROJECT_NAME}" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {PBX_GROUP_MAIN_ID};
			productRefGroup = {PBX_GROUP_PRODUCTS_ID} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{PBX_NATIVE_TARGET_ID} /* {TARGET_NAME} */,
			);
		}};
/* End PBXProject section */

/* Begin PBXSourcesBuildPhase section */
		{PBX_SOURCES_BUILD_PHASE_ID} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{PBX_BUILD_FILE_ID} /* {os.path.basename(SOURCE_FILE)} in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXFrameworksBuildPhase section */
		{PBX_FRAMEWORKS_BUILD_PHASE_ID} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXResourcesBuildPhase section */
		{PBX_RESOURCES_BUILD_PHASE_ID} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{PBX_CONFIG_DEBUG_PROJ_ID} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				MTL_FAST_MATH = YES;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{PBX_CONFIG_RELEASE_PROJ_ID} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				MTL_FAST_MATH = YES;
				SDKROOT = macosx;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
			}};
			name = Release;
		}};
		{PBX_CONFIG_DEBUG_TARGET_ID} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_STYLE = Automatic;
				CODE_SIGN_ENTITLEMENTS = "Tests/UITests/ClipKittyUITests.entitlements";
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 5.0;
				LD_RUNPATH_SEARCH_PATHS = (
                    "$(inherited)",
                    "@executable_path/../Frameworks",
                    "@loader_path/../Frameworks",
                );
			}};
			name = Debug;
		}};
		{PBX_CONFIG_RELEASE_TARGET_ID} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_STYLE = Automatic;
				CODE_SIGN_ENTITLEMENTS = "Tests/UITests/ClipKittyUITests.entitlements";
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 5.0;
				LD_RUNPATH_SEARCH_PATHS = (
                    "$(inherited)",
                    "@executable_path/../Frameworks",
                    "@loader_path/../Frameworks",
                );
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{PBX_CONFIG_LIST_PROJECT_ID} /* Build configuration list for PBXProject "{PROJECT_NAME}" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{PBX_CONFIG_DEBUG_PROJ_ID} /* Debug */,
				{PBX_CONFIG_RELEASE_PROJ_ID} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{PBX_CONFIG_LIST_TARGET_ID} /* Build configuration list for PBXNativeTarget "{TARGET_NAME}" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{PBX_CONFIG_DEBUG_TARGET_ID} /* Debug */,
				{PBX_CONFIG_RELEASE_TARGET_ID} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {PBX_PROJECT_ID} /* Project object */;
}}
"""

os.makedirs(f"{PROJECT_NAME}.xcodeproj", exist_ok=True)
with open(f"{PROJECT_NAME}.xcodeproj/project.pbxproj", "w") as f:
    f.write(CONTENT)

# Scheme
SCHEME_CONTENT = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.3">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{PBX_NATIVE_TARGET_ID}"
               BuildableName = "{TARGET_NAME}.xctest"
               BlueprintName = "{TARGET_NAME}"
               ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{PBX_NATIVE_TARGET_ID}"
               BuildableName = "{TARGET_NAME}.xctest"
               BlueprintName = "{TARGET_NAME}"
               ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
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
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
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

os.makedirs(f"{PROJECT_NAME}.xcodeproj/xcshareddata/schemes", exist_ok=True)
with open(f"{PROJECT_NAME}.xcodeproj/xcshareddata/schemes/{TARGET_NAME}.xcscheme", "w") as f:
    f.write(SCHEME_CONTENT)

print(f"Generated {PROJECT_NAME}.xcodeproj")
