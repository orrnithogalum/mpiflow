add_executable(test_mpi test_mpi.c)
target_link_libraries(test_mpi PRIVATE MPI::MPI_C)

# Nombre de rangs du test d'intégration (petit : les runners CI ont 2 à 4 cœurs)
set(MPIFLOW_TEST_NPROCS 4 CACHE STRING "Nombre de rangs MPI pour CTest")

# Options propres au lanceur. En CI (conteneur root, peu de cœurs) :
#   -DMPIEXEC_PREFLAGS="--allow-run-as-root;--oversubscribe"
foreach(np 1 ${MPIFLOW_TEST_NPROCS})
  add_test(NAME mpi_bcast_np${np}
           COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} ${np}
                   ${MPIEXEC_PREFLAGS} $<TARGET_FILE:test_mpi> ${MPIEXEC_POSTFLAGS})
  set_tests_properties(mpi_bcast_np${np} PROPERTIES
                       ENVIRONMENT "EXPECTED_RANKS=${np}"
                       PROCESSORS ${np}
                       TIMEOUT 60)
endforeach()
