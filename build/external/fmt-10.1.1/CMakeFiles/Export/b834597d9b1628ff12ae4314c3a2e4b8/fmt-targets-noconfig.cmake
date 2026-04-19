#----------------------------------------------------------------
# Generated CMake target import file.
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "fmt::fmt" for configuration ""
set_property(TARGET fmt::fmt APPEND PROPERTY IMPORTED_CONFIGURATIONS NOCONFIG)
set_target_properties(fmt::fmt PROPERTIES
  IMPORTED_LOCATION_NOCONFIG "${_IMPORT_PREFIX}/lib/libfmt.so.10.1.0"
  IMPORTED_SONAME_NOCONFIG "libfmt.so.10"
  )

list(APPEND _cmake_import_check_targets fmt::fmt )
list(APPEND _cmake_import_check_files_for_fmt::fmt "${_IMPORT_PREFIX}/lib/libfmt.so.10.1.0" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
