/* Aims to demonstrate the effect of loop vectorization and unrolling
 *
 * Compile via
 *
 *   cc -O2 -fno-vectorize -fno-unroll-loops unroll.c -o unroll
 *
 * Execute via
 *
 *   ./unroll  or  ./unroll -u (← peforms unrolling)
 */
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <sys/time.h>

#define MICROSECS(t) (1000000 * (t).tv_sec + (t).tv_usec)

#define SIZE (256 * 1024 * 1024)

void BATcalcsub(int *left, int *right, int *result)
{
  int i, j, k;

  for (i = j = k = 0; k < SIZE; i += 1, j += 1, k += 1) {
      result[k] = left[i] - right[j];
  }
}

void BATcalcsub_unrolled(int *left, int *right, int *result)
{
  int i, j, k;

  for (i = j = k = 0; k < SIZE; i += 4, j += 4, k += 4) {
      result[k  ] = left[i  ] - right[j  ];
      result[k+1] = left[i+1] - right[j+1];
      result[k+2] = left[i+2] - right[j+2];
      result[k+3] = left[i+3] - right[j+3];
  }
}

int main(int argc, char **argv)
{
  int *e1, *e2, *e3;
  struct timeval t0, t1;
  unsigned long duration;

  /* option -u: perform unrolling */
  int unroll = 0;
  unroll = getopt(argc, argv, "u") == 'u';

  e1 = malloc(SIZE * sizeof(int));
  e2 = malloc(SIZE * sizeof(int));
  e3 = malloc(SIZE * sizeof(int));
  assert(e1);
  assert(e2);
  assert(e3);

  for (int i = 0; i < SIZE; i += 1)
      e1[i] = e2[i] = e3[i] = 42;

  gettimeofday(&t0, NULL);
  if (unroll)
    BATcalcsub_unrolled(e1, e2, e3);
  else
    BATcalcsub(e1, e2, e3);
  gettimeofday(&t1, NULL);

  duration = MICROSECS(t1) - MICROSECS(t0);
  printf("time: %luμs (e3[42] = %d)\n", duration, e3[42]);

  return 0;
}
