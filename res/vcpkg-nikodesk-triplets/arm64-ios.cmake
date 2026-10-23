# vcpkg's arm64-ios triplet with the iOS app's minimum version. aom 3.15 also
# builds its command-line apps unless ENABLE_APPS is off, and an iOS executable
# is a bundle its install rule has no destination for.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_DEPLOYMENT_TARGET 15.0)
if(PORT STREQUAL "aom")
  set(VCPKG_CMAKE_CONFIGURE_OPTIONS -DENABLE_APPS=OFF)
endif()
