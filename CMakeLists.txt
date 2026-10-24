cmake_minimum_required(VERSION 3.20)
project(mpiflow VERSION 0.1.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)   # utilisé par clang-tidy / cppcheck

find_package(MPI REQUIRED COMPONENTS C)

include(CTest)                          # active enable_testing() + option BUILD_TESTING
add_subdirectory(tests)

# --- Installation / packaging local (cmake --install, cpack -G TGZ) -----------
# En CI, le job « package » fabrique le tarball avec tar : l'arbre de build
# contient des chemins absolus et n'est pas relocalisable d'un job à l'autre.
install(TARGETS test_mpi RUNTIME DESTINATION bin)
install(FILES README.md DESTINATION share/doc/mpiflow)
set(CPACK_GENERATOR "TGZ")
set(CPACK_PACKAGE_VENDOR "M2 CHPS - CHPS0902")
include(CPack)
