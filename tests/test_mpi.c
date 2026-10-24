/*
 * test_mpi.c -- test d'intégration MPI minimal (projet mpiflow, Cours 6 CHPS0902)
 *
 * Vérifie :
 *   1. MPI_Bcast   : la valeur 42 diffusée par le rang 0 arrive sur tous les rangs ;
 *   2. MPI_Allreduce : chaque rang participe (somme des rangs = n(n-1)/2) ;
 *   3. la taille du communicateur : si EXPECTED_RANKS est défini (CTest, Slurm),
 *      MPI_COMM_WORLD doit contenir exactement ce nombre de rangs. Cela détecte
 *      un lancement en « singletons » (srun sans support PMI : N programmes
 *      indépendants de taille 1 qui réussissent tous... à tort).
 *
 * Les vérifications n'utilisent PAS assert() : en CMAKE_BUILD_TYPE=Release,
 * -DNDEBUG supprime les assert() et le test passerait toujours.
 */
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    MPI_Init(&argc, &argv);

    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    int errors = 0;

    /* 1. Broadcast depuis le rang 0 */
    int data = (rank == 0) ? 42 : 0;
    MPI_Bcast(&data, 1, MPI_INT, 0, MPI_COMM_WORLD);
    if (data != 42) {
        fprintf(stderr, "[rang %d] MPI_Bcast : reçu %d au lieu de 42\n", rank, data);
        errors++;
    }

    /* 2. Allreduce : tous les rangs participent */
    long sum = 0, mine = rank;
    MPI_Allreduce(&mine, &sum, 1, MPI_LONG, MPI_SUM, MPI_COMM_WORLD);
    long expected_sum = (long)size * (size - 1) / 2;
    if (sum != expected_sum) {
        fprintf(stderr, "[rang %d] MPI_Allreduce : %ld au lieu de %ld\n", rank, sum, expected_sum);
        errors++;
    }

    /* 3. Taille attendue du communicateur */
    const char *env = getenv("EXPECTED_RANKS");
    if (env != NULL && atoi(env) > 0 && atoi(env) != size) {
        fprintf(stderr, "[rang %d] taille de MPI_COMM_WORLD = %d, attendu %s "
                        "(lancement sans PMI ?)\n", rank, size, env);
        errors++;
    }

    /* Placement des rangs : utile pour prouver une exécution multi-nœuds */
    char host[MPI_MAX_PROCESSOR_NAME] = {0};
    int len;
    MPI_Get_processor_name(host, &len);
    char *hosts = NULL;
    if (rank == 0)
        hosts = malloc((size_t)size * MPI_MAX_PROCESSOR_NAME);
    MPI_Gather(host, MPI_MAX_PROCESSOR_NAME, MPI_CHAR,
               hosts, MPI_MAX_PROCESSOR_NAME, MPI_CHAR, 0, MPI_COMM_WORLD);

    int total_errors = 0;
    MPI_Allreduce(&errors, &total_errors, 1, MPI_INT, MPI_SUM, MPI_COMM_WORLD);

    if (rank == 0) {
        int nhosts = 0;
        for (int r = 0; r < size; r++) {
            const char *h = hosts + (size_t)r * MPI_MAX_PROCESSOR_NAME;
            int seen = 0;
            for (int q = 0; q < r && !seen; q++)
                seen = !strcmp(h, hosts + (size_t)q * MPI_MAX_PROCESSOR_NAME);
            nhosts += !seen;
            printf("  rang %d sur %s\n", r, h);
        }
        free(hosts);
        if (total_errors == 0)
            printf("MPI test passed with %d ranks on %d host(s)\n", size, nhosts);
        else
            printf("MPI test FAILED: %d error(s) on %d ranks\n", total_errors, size);
    }

    MPI_Finalize();
    return total_errors == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
