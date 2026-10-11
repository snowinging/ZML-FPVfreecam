cmake_minimum_required(VERSION 3.25)
project(EndfieldFreeCam VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(MSVC)
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  add_compile_options(/utf-8 /W4 /permissive-)
endif()
add_compile_definitions(UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)

add_library(FreeCam SHARED src/plugin.cpp src/fpvlink.cpp)
target_include_directories(FreeCam PRIVATE src sdk/include)
target_link_libraries(FreeCam PRIVATE ws2_32)
set_target_properties(FreeCam PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/package/$<CONFIG>/freecam")

add_custom_target(package ALL DEPENDS FreeCam)
foreach(file mod.ini config.ini icon.png freecam.lua freecam_core.lua fpv_link.lua zml-package.json)
  add_custom_command(TARGET package POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy
    "${CMAKE_CURRENT_SOURCE_DIR}/mod/${file}" "${CMAKE_BINARY_DIR}/package/$<CONFIG>/freecam/${file}")
endforeach()
