cmake_minimum_required(VERSION 3.24)
project(edge_one_core VERSION 0.1.0 LANGUAGES C CXX)

include(CTest)
include(FetchContent)
find_package(Threads REQUIRED)
# Matches spikes/m0/pins.json. Source only; this never fetches model weights.
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
FetchContent_Declare(llama_cpp
  URL https://codeload.github.com/ggml-org/llama.cpp/tar.gz/441df11f65ea0b6d0c72965aaf70c8241070ddcb
  URL_HASH SHA256=d55c444401db6734c2f4bba77c4d270f0e431c9e197ce5f35da8abe19a08c91b
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(llama_cpp)

add_library(edge_one_request STATIC src/request.cpp src/renderer.cpp)
target_compile_features(edge_one_request PUBLIC cxx_std_17)
target_include_directories(edge_one_request PUBLIC src)
target_include_directories(edge_one_request SYSTEM PUBLIC "${llama_cpp_SOURCE_DIR}/vendor")
set_target_properties(edge_one_request PROPERTIES POSITION_INDEPENDENT_CODE ON
  CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)

add_library(edge_one_core SHARED src/api.cpp src/response.cpp src/llama_backend.cpp)
target_compile_features(edge_one_core PUBLIC cxx_std_17)
target_include_directories(edge_one_core PUBLIC include)
target_compile_definitions(edge_one_core PRIVATE EDGE_ONE_BUILD)
target_link_libraries(edge_one_core PRIVATE edge_one_request llama Threads::Threads)
set_target_properties(edge_one_core PROPERTIES
  CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON
  VERSION ${PROJECT_VERSION} SOVERSION 0)

if(UNIX AND NOT APPLE)
  target_link_options(edge_one_core PRIVATE
    "LINKER:--version-script=${CMAKE_CURRENT_SOURCE_DIR}/src/exports.map")
  set_property(TARGET edge_one_core APPEND PROPERTY LINK_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/src/exports.map")
endif()

if(BUILD_TESTING)
  add_executable(edge_one_request_test tests/request_test.cpp)
  target_link_libraries(edge_one_request_test PRIVATE edge_one_request)
  add_test(NAME edge_one_request COMMAND edge_one_request_test
    "${CMAKE_CURRENT_SOURCE_DIR}/../edge_one_flutter/assets/model_manifest.json"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../schemas/fixtures/system-one-v1-cases.json")
  add_executable(edge_one_response_test tests/response_test.cpp src/response.cpp)
  target_include_directories(edge_one_response_test PRIVATE include)
  target_link_libraries(edge_one_response_test PRIVATE edge_one_request Threads::Threads)
  add_test(NAME edge_one_response COMMAND edge_one_response_test
    "${CMAKE_CURRENT_SOURCE_DIR}/../edge_one_flutter/assets/model_manifest.json")
  # Compile private seams into tests; they are not exported by the shared library.
  add_executable(edge_one_api_test tests/api_test.cpp src/api.cpp src/response.cpp src/llama_backend.cpp)
  target_include_directories(edge_one_api_test PRIVATE include)
  target_compile_definitions(edge_one_api_test PRIVATE EDGE_ONE_BUILD)
  target_link_libraries(edge_one_api_test PRIVATE edge_one_request llama Threads::Threads)
  add_test(NAME edge_one_api COMMAND edge_one_api_test
    "${CMAKE_CURRENT_SOURCE_DIR}/../edge_one_flutter/assets/model_manifest.json")
  if(UNIX AND NOT APPLE)
    add_test(NAME edge_one_exports COMMAND ${CMAKE_COMMAND}
      "-DNM=${CMAKE_NM}" "-DLIBRARY=$<TARGET_FILE:edge_one_core>"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/tests/check_exports.cmake")
  endif()
  add_executable(edge_one_c_client tests/c_client.c)
  target_link_libraries(edge_one_c_client PRIVATE edge_one_core)
  add_test(NAME edge_one_c_client COMMAND edge_one_c_client)
endif()
