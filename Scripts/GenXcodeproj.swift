#!/usr/bin/env swift
// Generates minimal Xcode project for UI Tests

import Foundation

func generateUUID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).uppercased()
}

let projectName = "ClipKitty"
let targetName = "ClipKittyUITests"
let bundleId = "com.clipkitty.UITests"

// Find all swift files in Tests/UITests
let fm = FileManager.default
let uiTestsPath = "Tests/UITests"
let sourceFiles: [String] = (try? fm.contentsOfDirectory(atPath: uiTestsPath))?.filter { $0.hasSuffix(".swift") }.map { "\(uiTestsPath)/\($0)" } ?? []

// UUIDs
let pbxProjectId = generateUUID()
let pbxGroupMainId = generateUUID()
let pbxGroupTestsId = generateUUID()
let pbxNativeTargetId = generateUUID()
let pbxConfigListProjectId = generateUUID()
let pbxConfigListTargetId = generateUUID()
let pbxConfigDebugProjId = generateUUID()
let pbxConfigReleaseProjId = generateUUID()
let pbxConfigDebugTargetId = generateUUID()
let pbxConfigReleaseTargetId = generateUUID()
let pbxSourcesBuildPhaseId = generateUUID()
let pbxFrameworksBuildPhaseId = generateUUID()
let pbxResourcesBuildPhaseId = generateUUID()
let pbxProductRefId = generateUUID()
let pbxGroupProductsId = generateUUID()

struct SourceFile {
    let path: String
    let basename: String
    let fileId: String
    let buildId: String
}

let sources = sourceFiles.map { path -> SourceFile in
    SourceFile(path: path, basename: URL(fileURLWithPath: path).lastPathComponent, fileId: generateUUID(), buildId: generateUUID())
}

var content = """
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 55;
	objects = {

/* Begin PBXBuildFile section */
"""

for source in sources {
    content += "\n\t\t\(source.buildId) /* \(source.basename) in Sources */ = {isa = PBXBuildFile; fileRef = \(source.fileId) /* \(source.basename) */; };"
}

content += """

/* End PBXBuildFile section */

/* Begin PBXFileReference section */
"""

for source in sources {
    content += "\n\t\t\(source.fileId) /* \(source.basename) */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"\(source.path)\"; sourceTree = \"<group>\"; };"
}

content += """

		\(pbxProductRefId) /* \(targetName).xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = \"\(targetName).xctest\"; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXGroup section */
		\(pbxGroupMainId) = {
			isa = PBXGroup;
			children = (
				\(pbxGroupTestsId) /* Tests */,
				\(pbxGroupProductsId) /* Products */,
			);
			sourceTree = \"<group>\";
		};
		\(pbxGroupProductsId) /* Products */ = {
			isa = PBXGroup;
			children = (
				\(pbxProductRefId) /* \(targetName).xctest */,
			);
			name = Products;
			sourceTree = \"<group>\";
		};
		\(pbxGroupTestsId) /* Tests */ = {
			isa = PBXGroup;
			children = (
"""

for source in sources {
    content += "\n\t\t\t\t\(source.fileId) /* \(source.basename) */,"
}

content += """

			);
			path = ".";
			sourceTree = \"<group>\";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		\(pbxNativeTargetId) /* \(targetName) */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = \(pbxConfigListTargetId) /* Build configuration list for PBXNativeTarget \"\(targetName)\" */;
			buildPhases = (
				\(pbxSourcesBuildPhaseId) /* Sources */,
				\(pbxFrameworksBuildPhaseId) /* Frameworks */,
				\(pbxResourcesBuildPhaseId) /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = \"\(targetName)\";
			productName = \"\(targetName)\";
			productReference = \(pbxProductRefId) /* \(targetName).xctest */;
			productType = \"com.apple.product-type.bundle.ui-testing\";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		\(pbxProjectId) /* Project object */ = {
			isa = PBXProject;
			attributes = {
				LastUpgradeCheck = 1500;
				TargetAttributes = {
					\(pbxNativeTargetId) = {
						CreatedOnToolsVersion = 15.0;
						TestTargetID = \(pbxNativeTargetId);
					};
				};
			};
			buildConfigurationList = \(pbxConfigListProjectId) /* Build configuration list for PBXProject \"\(projectName)\" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = \(pbxGroupMainId);
			productRefGroup = \(pbxGroupProductsId) /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				\(pbxNativeTargetId) /* \(targetName) */,
			);
		};
/* End PBXProject section */

/* Begin PBXSourcesBuildPhase section */
		\(pbxSourcesBuildPhaseId) /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
"""

for source in sources {
    content += "\n\t\t\t\t\(source.buildId) /* \(source.basename) in Sources */,"
}

content += """

			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin PBXFrameworksBuildPhase section */
		\(pbxFrameworksBuildPhaseId) /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXResourcesBuildPhase section */
		\(pbxResourcesBuildPhaseId) /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		\(pbxConfigDebugProjId) /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = \"gnu++20\";
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
			};
			name = Debug;
		};
		\(pbxConfigReleaseProjId) /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = \"gnu++20\";
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
			};
			name = Release;
		};
		\(pbxConfigDebugTargetId) /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				CODE_SIGN_ENTITLEMENTS = "Tests/UITests/ClipKittyUITests.entitlements";
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = \(bundleId);
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 5.0;
				LD_RUNPATH_SEARCH_PATHS = (
                    "$(inherited)",
                    "@executable_path/../Frameworks",
                    "@loader_path/../Frameworks",
                );
			};
			name = Debug;
		};
		\(pbxConfigReleaseTargetId) /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				CODE_SIGN_ENTITLEMENTS = "Tests/UITests/ClipKittyUITests.entitlements";
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = \(bundleId);
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 5.0;
				LD_RUNPATH_SEARCH_PATHS = (
                    "$(inherited)",
                    "@executable_path/../Frameworks",
                    "@loader_path/../Frameworks",
                );
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		\(pbxConfigListProjectId) /* Build configuration list for PBXProject \"\(projectName)\" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				\(pbxConfigDebugProjId) /* Debug */,
				\(pbxConfigReleaseProjId) /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		\(pbxConfigListTargetId) /* Build configuration list for PBXNativeTarget \"\(targetName)\" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				\(pbxConfigDebugTargetId) /* Debug */,
				\(pbxConfigReleaseTargetId) /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
	};
	rootObject = \(pbxProjectId) /* Project object */;
}
""";

let schemeContent = """
<?xml version="1.0" encoding="UTF-8"?>
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
               BlueprintIdentifier = \"\(pbxNativeTargetId)\" 
               BuildableName = \"\(targetName).xctest\"
               BlueprintName = \"\(targetName)\" 
               ReferencedContainer = "container:\(projectName).xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <EnvironmentVariables>
         <EnvironmentVariable
            key = "CLIPKITTY_APP_PATH"
            value = "$(PROJECT_DIR)/ClipKitty.app"
            isEnabled = "YES">
         </EnvironmentVariable>
      </EnvironmentVariables>
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = \"\(pbxNativeTargetId)\" 
               BuildableName = \"\(targetName).xctest\"
               BlueprintName = \"\(targetName)\" 
               ReferencedContainer = "container:\(projectName).xcodeproj">
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
      <EnvironmentVariables>
         <EnvironmentVariable
            key = "CLIPKITTY_APP_PATH"
            value = "$(PROJECT_DIR)/ClipKitty.app"
            isEnabled = "YES">
         </EnvironmentVariable>
      </EnvironmentVariables>
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
""";

let projectDir = "\(projectName).xcodeproj"
let schemesDir = "\(projectDir)/xcshareddata/schemes"

try fm.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
try fm.createDirectory(atPath: schemesDir, withIntermediateDirectories: true)

try content.write(toFile: "\(projectDir)/project.pbxproj", atomically: true, encoding: .utf8)
try schemeContent.write(toFile: "\(schemesDir)/\(targetName).xcscheme", atomically: true, encoding: .utf8)

print("Generated \(projectName).xcodeproj")