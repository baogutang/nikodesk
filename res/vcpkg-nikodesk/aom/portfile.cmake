# NASM is required to build AOM
vcpkg_find_acquire_program(NASM)
get_filename_component(NASM_EXE_PATH ${NASM} DIRECTORY)
vcpkg_add_to_path(${NASM_EXE_PATH})

# Perl is required to build AOM
vcpkg_find_acquire_program(PERL)
get_filename_component(PERL_PATH ${PERL} DIRECTORY)
vcpkg_add_to_path(${PERL_PATH})

# NikoDesk: official release archive exactly matches Git commit
# 44d0a57786f432d933ff64b653347c66f4d0fa1d, tree 1083b6eece30f9d8279a057b9cc05bded50c5ed8.
# Deliberately do not allow USE_AOM_391 to bypass the security baseline.
if(DEFINED ENV{USE_AOM_391})
    message(FATAL_ERROR "NikoDesk requires AOM 3.15.1; USE_AOM_391 is not supported")
endif()
set(AOM_CONFIG_PATH "lib/cmake/AOM")
vcpkg_download_distfile(AOM_ARCHIVE
    URLS "https://storage.googleapis.com/aom-releases/libaom-3.15.1.tar.gz"
    FILENAME "libaom-3.15.1.tar.gz"
    SHA512 0e1f93b0ddff4754d408e48adc2c4c0985db2f3b55aa89706e8584c9a386bafd2217a2dd4e4b08dfe82be85208038f2b3ae5a8ba908b6b04396ee612840a5cc5
)
vcpkg_extract_source_archive(SOURCE_PATH
    ARCHIVE "${AOM_ARCHIVE}"
    PATCHES aom-uninitialized-pointer.diff
)

set(aom_target_cpu "")
if(VCPKG_TARGET_IS_UWP OR (VCPKG_TARGET_IS_WINDOWS AND VCPKG_TARGET_ARCHITECTURE MATCHES "^arm"))
    # UWP + aom's assembler files result in weirdness and build failures
    # Also, disable assembly on ARM and ARM64 Windows to fix compilation issues.
    set(aom_target_cpu "-DAOM_TARGET_CPU=generic")
endif()

if(VCPKG_TARGET_ARCHITECTURE STREQUAL "arm" AND VCPKG_TARGET_IS_LINUX)
  set(aom_target_cpu "-DENABLE_NEON=OFF")
endif()

vcpkg_cmake_configure(
    SOURCE_PATH ${SOURCE_PATH}
    OPTIONS
        ${aom_target_cpu}
        -DENABLE_DOCS=OFF
        -DENABLE_EXAMPLES=OFF
        -DENABLE_TESTDATA=OFF
        -DENABLE_TESTS=OFF
        -DENABLE_TOOLS=OFF
)

vcpkg_cmake_install()

vcpkg_copy_pdbs()

vcpkg_fixup_pkgconfig()

if(VCPKG_TARGET_IS_WINDOWS)
  vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/lib/pkgconfig/aom.pc" " -lm" "")
  if(NOT VCPKG_BUILD_TYPE)
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/debug/lib/pkgconfig/aom.pc" " -lm" "")
  endif()
endif()

# Move cmake configs
vcpkg_cmake_config_fixup(CONFIG_PATH ${AOM_CONFIG_PATH})

# Remove duplicate files
file(REMOVE_RECURSE ${CURRENT_PACKAGES_DIR}/debug/include
                    ${CURRENT_PACKAGES_DIR}/debug/share)

# Handle copyright
file(INSTALL ${SOURCE_PATH}/LICENSE DESTINATION ${CURRENT_PACKAGES_DIR}/share/${PORT} RENAME copyright)

vcpkg_fixup_pkgconfig()
