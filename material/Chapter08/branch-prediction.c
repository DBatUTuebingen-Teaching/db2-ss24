/* Demonstrate the effects of branch mispredictions for a selection
 * col < v implemented in a tight loop
 */
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <assert.h>

#define MICROSECS(t) (1000000 * (t).tv_sec + (t).tv_usec)

#define SIZE (32 * 1024 * 1024)
#define STEPS 11

/* comparison of a, b (only used in qsort, Experiment (1)) */
int cmp (const void *a, const void *b)
{
    return *((int*) a) - *((int*) b);
}

int main()
{
    int *col;        /* column vector */
    int *sv;         /* selection vector */

    int out;
    float selectivity;

    struct timeval t0, t1;
    unsigned long duration;

    /* allocate memory */
    col = malloc(SIZE * sizeof(int));
    assert(col);
    sv = malloc(SIZE * sizeof(int));
    assert(sv);

    /* initialize column with (pseudo) random values in interval 0...RAND_MAX */
    srand(42);
    for (int i = 0; i < SIZE; i += 1) {
        col[i] = rand();
    }

    /* Experiment (1) only:
     */
    // qsort(col, SIZE, sizeof(int), cmp);

    for (int step = 0; step < STEPS; step += 1) {

        /* v grows linearly 0...RAND_MAX in STEPS steps */
        int v = step * (RAND_MAX / (STEPS - 1));

        gettimeofday(&t0, NULL);

        out = 0;
        for (int i = 0; i < SIZE; i += 1) {

            // if (col[i] < v) {
            //     sv[out] = i;
            //     out += 1;
            // }

            /* Experiment (2) only:
             * a branch-less copy
             */
            sv[out] = i;
            out += (col[i] < v);
        }

        gettimeofday(&t1, NULL);
        duration = MICROSECS(t1) - MICROSECS(t0);

        selectivity = ((float)out / SIZE) * 100.0;

        printf ("%2u (selectivity: %6.2f%%)\t%luμs\n",
                step, selectivity, duration);
    }

    return 0;
}
