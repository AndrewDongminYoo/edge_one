cmake_minimum_required(VERSION 3.16)
project(edge_one_core LANGUAGES CXX)

add_library(edge_one_core INTERFACE)
target_compile_features(edge_one_core INTERFACE cxx_std_17)
