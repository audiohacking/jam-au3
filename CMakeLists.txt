cmake_minimum_required(VERSION 3.27)

set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum OS X deployment version" FORCE)

find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM)
  set(CMAKE_C_COMPILER_LAUNCHER "${CCACHE_PROGRAM}" CACHE STRING "C compiler launcher" FORCE)
  set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}" CACHE STRING "C++ compiler launcher" FORCE)
  set(CMAKE_OBJCXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}" CACHE STRING "ObjC++ compiler launcher" FORCE)
  message(STATUS "Using ccache: ${CCACHE_PROGRAM}")
endif()

project(jam-au3 LANGUAGES C CXX OBJCXX)

if(NOT APPLE)
  message(FATAL_ERROR
    "jam-au3 is macOS-only (MLX/Metal + Apple frameworks).\n"
    "The magenta-realtime submodule provides magentart::core for inference.")
endif()

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Release" CACHE STRING "Choose the type of build." FORCE)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(ABSL_INTERNAL_AT_LEAST_CXX20 ON CACHE BOOL "Force Abseil C++20 support")
set(ABSL_PROPAGATE_CXX_STD ON)

set(MAGENTA_RT_DIR "${CMAKE_SOURCE_DIR}/magenta-realtime")
set(JAM_COMMON_DIR "${MAGENTA_RT_DIR}/examples/common")
set(JAM_UI_DIR "${MAGENTA_RT_DIR}/examples/jam/ui")

if(EXISTS "${CMAKE_SOURCE_DIR}/jam-ui-patches/App.tsx")
  file(COPY "${CMAKE_SOURCE_DIR}/jam-ui-patches/App.tsx"
       DESTINATION "${JAM_UI_DIR}/src/")
  message(STATUS "Applied jam-ui-patches overlay to Jam React UI")
endif()

if(NOT EXISTS "${MAGENTA_RT_DIR}/core/CMakeLists.txt")
  message(FATAL_ERROR
    "magenta-realtime submodule is missing. Run:\n"
    "  git submodule update --init --recursive")
endif()

# Overlay jam-au3 core fixes onto the submodule at configure time (bounce safety,
# process-wide MLX GPU lock). Keeps CI working without a magenta-realtime fork.
set(JAM_CORE_PATCH_DIR "${CMAKE_SOURCE_DIR}/jam-core-patches")
if(EXISTS "${JAM_CORE_PATCH_DIR}/core/src/realtime_runner.cpp")
  file(COPY "${JAM_CORE_PATCH_DIR}/core/"
       DESTINATION "${MAGENTA_RT_DIR}/core/"
       FILES_MATCHING PATTERN "*")
  message(STATUS "Applied jam-core-patches overlay to magenta-realtime/core")
endif()

set(MAGENTART_VERSION "0.0.1")
add_definitions(-DMAGENTART_VERSION="${MAGENTART_VERSION}")

execute_process(
  COMMAND git rev-parse --short HEAD
  WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
  OUTPUT_VARIABLE MAGENTART_GIT_SHA
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET
)
if(NOT MAGENTART_GIT_SHA)
  set(MAGENTART_GIT_SHA "unknown")
endif()
add_definitions(-DMAGENTART_GIT_SHA="${MAGENTART_GIT_SHA}")

include(FetchContent)

FetchContent_Declare(
  mlx
  GIT_REPOSITORY https://github.com/ml-explore/mlx.git
  GIT_TAG v0.31.1
  GIT_SHALLOW ON
)
set(MLX_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(MLX_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(MLX_BUILD_BENCHMARKS OFF CACHE BOOL "" FORCE)
set(MLX_BUILD_PYTHON_BINDINGS OFF CACHE BOOL "" FORCE)
set(MLX_BUILD_PYTHON_STUBS OFF CACHE BOOL "" FORCE)
set(MLX_BUILD_GGUF OFF CACHE BOOL "" FORCE)
set(MLX_BUILD_CUDA OFF CACHE BOOL "" FORCE)
message(STATUS "Fetching MLX... (this may take a moment)")
FetchContent_MakeAvailable(mlx)

file(READ "${mlx_SOURCE_DIR}/mlx/backend/metal/make_compiled_preamble.sh" MLX_CONTENT)
string(REPLACE
  "declare -a HDRS_LIST=($HDRS)"
  "declare -a HDRS_LIST=(); while read -r dots path; do [ -n \"$dots\" ] && HDRS_LIST+=(\"$dots\" \"$path\"); done <<< \"$HDRS\""
  MLX_CONTENT
  "${MLX_CONTENT}"
)
file(WRITE "${mlx_SOURCE_DIR}/mlx/backend/metal/make_compiled_preamble.sh" "${MLX_CONTENT}")

FetchContent_Declare(
  sentencepiece
  GIT_REPOSITORY https://github.com/google/sentencepiece.git
  GIT_TAG v0.2.0
  GIT_SHALLOW ON
)
set(SPM_ENABLE_SHARED OFF CACHE BOOL "" FORCE)
message(STATUS "Fetching sentencepiece... (this may take a moment)")
FetchContent_MakeAvailable(sentencepiece)

FetchContent_Declare(
  tensorflow-lite
  GIT_REPOSITORY https://github.com/tensorflow/tensorflow.git
  GIT_TAG v2.21.0
  SOURCE_SUBDIR tensorflow/lite
  GIT_SHALLOW ON
)
set(TFLITE_ENABLE_XNNPACK OFF CACHE BOOL "Disable XNNPACK delegate" FORCE)
set(TFLITE_ENABLE_GPU OFF CACHE BOOL "Disable GPU delegate" FORCE)
set(TFLITE_BUILD_TESTS OFF CACHE BOOL "Disable tests" FORCE)
set(FETCHCONTENT_SOURCE_DIR_TENSORFLOW "${CMAKE_BINARY_DIR}/_deps/tensorflow-lite-src" CACHE PATH
  "Point TF Lite's internal TF fetch at our already-cloned v2.21.0 source" FORCE)
message(STATUS "Fetching tensorflow-lite... (this may take a long time due to repo size)")
FetchContent_MakeAvailable(tensorflow-lite)

set(CODESIGN_IDENTITY "" CACHE STRING
  "Override code signing identity (else uses \$MAGENTART_DEVELOPER_ID, else ad-hoc '-')")
if(NOT CODESIGN_IDENTITY OR CODESIGN_IDENTITY STREQUAL "-")
  if(DEFINED ENV{MAGENTART_DEVELOPER_ID} AND NOT "$ENV{MAGENTART_DEVELOPER_ID}" STREQUAL "")
    set(CODESIGN_IDENTITY "$ENV{MAGENTART_DEVELOPER_ID}")
    message(STATUS "CODESIGN_IDENTITY from \$MAGENTART_DEVELOPER_ID: ${CODESIGN_IDENTITY}")
  else()
    set(CODESIGN_IDENTITY "-")
  endif()
endif()
set(NOTARYTOOL_KEYCHAIN_PROFILE "notarytool-creds" CACHE STRING
  "Keychain profile name for `xcrun notarytool`")

if(CODESIGN_IDENTITY STREQUAL "-")
  set(CODESIGN_FLAGS --force --sign "${CODESIGN_IDENTITY}")
else()
  set(CODESIGN_FLAGS --force --sign "${CODESIGN_IDENTITY}"
    --options=runtime --timestamp)
endif()

function(magentart_add_notarize_target target_name)
  cmake_parse_arguments(N "" "APP;DEPENDS;ZIP_NAME" "EXTRA_FILES" ${ARGN})
  if(NOT N_APP OR NOT N_DEPENDS)
    message(FATAL_ERROR "magentart_add_notarize_target: APP and DEPENDS are required")
  endif()
  if(NOT N_ZIP_NAME)
    set(N_ZIP_NAME "${target_name}.zip")
  endif()

  if(CODESIGN_IDENTITY STREQUAL "-")
    add_custom_target(${target_name}
      COMMAND ${CMAKE_COMMAND} -E echo
        "ERROR: ${target_name} requires a Developer ID."
      COMMAND ${CMAKE_COMMAND} -E false
      COMMENT "${target_name} disabled (CODESIGN_IDENTITY is ad-hoc)"
    )
    return()
  endif()

  set(zip_path "${CMAKE_BINARY_DIR}/${N_ZIP_NAME}")
  get_filename_component(app_name "${N_APP}" NAME)
  set(staging_dir "${CMAKE_BINARY_DIR}/staging_${target_name}")

  set(prep_commands)
  list(APPEND prep_commands COMMAND ${CMAKE_COMMAND} -E rm -rf "${staging_dir}")
  list(APPEND prep_commands COMMAND ${CMAKE_COMMAND} -E make_directory "${staging_dir}")
  list(APPEND prep_commands COMMAND ditto "${N_APP}" "${staging_dir}/${app_name}")
  foreach(extra_file IN LISTS N_EXTRA_FILES)
    list(APPEND prep_commands COMMAND ${CMAKE_COMMAND} -E copy "${extra_file}" "${staging_dir}/")
  endforeach()

  add_custom_target(${target_name}
    DEPENDS ${N_DEPENDS}
    ${prep_commands}
    COMMAND ditto -c -k "${staging_dir}" "${zip_path}"
    COMMAND xcrun notarytool submit "${zip_path}"
      --keychain-profile "${NOTARYTOOL_KEYCHAIN_PROFILE}" --wait
    COMMAND xcrun stapler staple "${N_APP}"
    COMMAND xcrun stapler validate "${N_APP}"
    ${prep_commands}
    COMMAND ditto -c -k "${staging_dir}" "${zip_path}"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${staging_dir}"
    COMMENT "Notarizing ${N_APP} -> ${zip_path}"
    USES_TERMINAL
    VERBATIM
  )
endfunction()

option(MAGENTART_DEBUG_LOG "Enable AUv3 debug overlay + jam_debug.log file writer" OFF)
if(MAGENTART_DEBUG_LOG)
  add_compile_definitions(MAGENTART_DEBUG_LOG=1)
endif()

add_custom_target(npm_install_root
  COMMAND npm install
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Running npm workspaces install..."
)

add_custom_target(build_jam_ui ALL
  COMMAND npm run build --workspace=jam-ui
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Building Jam UI..."
)
add_dependencies(build_jam_ui npm_install_root)

add_subdirectory("${MAGENTA_RT_DIR}/core" magentart_core)

set(APP_ICON "${CMAKE_CURRENT_SOURCE_DIR}/assets/AppIcon.icns")
set_source_files_properties(${APP_ICON} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")

add_executable(jam_au MACOSX_BUNDLE
  Jam_AudioUnit.mm
  Jam_ViewController.mm
  JamModelPaths.mm
  JamModelDownloader.mm
  ${JAM_COMMON_DIR}/cpp/magenta_paths.cpp
  ${JAM_COMMON_DIR}/objc/MagentaModelManager.mm
  ${JAM_COMMON_DIR}/objc/MagentaSettings.mm
  ${APP_ICON}
)

target_link_options(jam_au PRIVATE -e _NSExtensionMain)

target_include_directories(jam_au PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${JAM_COMMON_DIR}/cpp
  ${JAM_COMMON_DIR}/objc
)
target_compile_options(jam_au PRIVATE -fobjc-arc)

target_link_libraries(jam_au PRIVATE
  magentart::core
  "-framework AppKit"
  "-framework AudioToolbox"
  "-framework AVFoundation"
  "-framework CoreAudioKit"
  "-framework WebKit"
  "-framework UniformTypeIdentifiers"
)

set_target_properties(jam_au PROPERTIES
  MACOSX_BUNDLE TRUE
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
  MACOSX_BUNDLE_EXECUTABLE_NAME Jam_AU
  MACOSX_BUNDLE_BUNDLE_NAME "Jam_AU"
  MACOSX_BUNDLE_ICON_FILE "AppIcon.icns"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.audiohacking.jam.au"
)

add_executable(jam_au_app MACOSX_BUNDLE
  Jam_AUHostApp.mm
  ${APP_ICON}
)

target_compile_options(jam_au_app PRIVATE -fobjc-arc)

target_link_libraries(jam_au_app PRIVATE
  "-framework Cocoa"
)

set_target_properties(jam_au_app PROPERTIES
  MACOSX_BUNDLE TRUE
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/HostInfo.plist.in"
  MACOSX_BUNDLE_EXECUTABLE_NAME Jam_AUApp
  MACOSX_BUNDLE_BUNDLE_NAME "Magenta Jam (AU)"
  MACOSX_BUNDLE_ICON_FILE "AppIcon.icns"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.audiohacking.jam.au.host"
)

add_dependencies(jam_au_app jam_au)
add_dependencies(jam_au_app build_jam_ui)

set(ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/Entitlements.plist")
set(JAM_AU_APP_BUNDLE_NAME "Magenta Jam (AU).app")
set(JAM_AU_PACKAGE_DIR "${CMAKE_BINARY_DIR}/dist")

function(jam_au_add_finalize_bundle_target target_name)
  add_custom_target(${target_name}
    DEPENDS jam_au_app jam_au
    COMMAND ${CMAKE_COMMAND} -E make_directory
      "$<TARGET_BUNDLE_DIR:jam_au_app>/Contents/PlugIns"
    COMMAND ${CMAKE_COMMAND} -E remove_directory
      "$<TARGET_BUNDLE_DIR:jam_au_app>/Contents/PlugIns/Jam_AU.appex"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
      "$<TARGET_BUNDLE_DIR:jam_au>"
      "$<TARGET_BUNDLE_DIR:jam_au_app>/Contents/PlugIns/Jam_AU.appex"
    COMMAND ${CMAKE_COMMAND} -E make_directory
      "$<TARGET_BUNDLE_DIR:jam_au_app>/Contents/PlugIns/Jam_AU.appex/Contents/Resources"
    COMMAND ${CMAKE_COMMAND} -E make_directory
      "$<TARGET_BUNDLE_DIR:jam_au_app>/Contents/PlugIns/Jam_AU.appex/Contents/Resources/jam_ui"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
      "${JAM_UI_DIR}/dist"
      "$<TARGET_BUNDLE_DIR:jam_au_app>/Contents/PlugIns/Jam_AU.appex/Contents/Resources/jam_ui"
    COMMAND ${CMAKE_COMMAND} -E copy
      "${mlx_BINARY_DIR}/mlx/backend/metal/kernels/mlx.metallib"
      "$<TARGET_BUNDLE_DIR:jam_au_app>/Contents/PlugIns/Jam_AU.appex/Contents/MacOS/mlx.metallib"
    COMMAND codesign ${CODESIGN_FLAGS}
      "$<TARGET_BUNDLE_DIR:jam_au_app>/Contents/PlugIns/Jam_AU.appex/Contents/MacOS/mlx.metallib"
    COMMAND codesign ${CODESIGN_FLAGS}
      --entitlements "${ENTITLEMENTS}" --generate-entitlement-der
      "$<TARGET_BUNDLE_DIR:jam_au_app>/Contents/PlugIns/Jam_AU.appex"
    COMMAND codesign ${CODESIGN_FLAGS}
      "$<TARGET_BUNDLE_DIR:jam_au_app>"
    COMMENT "Finalizing ${JAM_AU_APP_BUNDLE_NAME}"
    VERBATIM
  )
endfunction()

jam_au_add_finalize_bundle_target(finalize_jam_au)

add_custom_target(deploy_jam_au ALL
  DEPENDS finalize_jam_au
  COMMAND ${CMAKE_COMMAND} -E remove_directory
    "$ENV{HOME}/Applications/${JAM_AU_APP_BUNDLE_NAME}"
  COMMAND ditto
    "$<TARGET_BUNDLE_DIR:jam_au_app>"
    "$ENV{HOME}/Applications/${JAM_AU_APP_BUNDLE_NAME}"
  COMMAND sh -c "killall -9 AudioComponentRegistrar 2>/dev/null || true"
  COMMAND sleep 1
  COMMAND sh -c "pluginkit -a '$ENV{HOME}/Applications/${JAM_AU_APP_BUNDLE_NAME}/Contents/PlugIns/Jam_AU.appex' 2>/dev/null || true"
  COMMENT "Deploying ${JAM_AU_APP_BUNDLE_NAME} to ~/Applications"
  VERBATIM
)

add_custom_target(package_jam_au
  DEPENDS finalize_jam_au
  COMMAND ${CMAKE_COMMAND} -E rm -rf "${JAM_AU_PACKAGE_DIR}"
  COMMAND ${CMAKE_COMMAND} -E make_directory "${JAM_AU_PACKAGE_DIR}"
  COMMAND ditto
    "$<TARGET_BUNDLE_DIR:jam_au_app>"
    "${JAM_AU_PACKAGE_DIR}/${JAM_AU_APP_BUNDLE_NAME}"
  COMMAND ${CMAKE_COMMAND} -E copy
    "${CMAKE_CURRENT_SOURCE_DIR}/INSTALL.md"
    "${JAM_AU_PACKAGE_DIR}/INSTALL.md"
  COMMAND ${CMAKE_COMMAND} -E copy
    "${CMAKE_CURRENT_SOURCE_DIR}/AGENT.md"
    "${JAM_AU_PACKAGE_DIR}/AGENT.md"
  COMMENT "Staging ${JAM_AU_APP_BUNDLE_NAME} in ${JAM_AU_PACKAGE_DIR}"
  VERBATIM
)

magentart_add_notarize_target(notarize_jam_au
  APP "$ENV{HOME}/Applications/Magenta Jam (AU).app"
  DEPENDS deploy_jam_au
  ZIP_NAME "Jam_AU.zip"
  EXTRA_FILES "${CMAKE_CURRENT_SOURCE_DIR}/INSTALL.md"
)
