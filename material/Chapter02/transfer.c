#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <sys/time.h>
#include <stdint.h>

#define MICROSECS(t) (1000000 * (t).tv_sec + (t).tv_usec)

/* overall size of memory to scan (64 GB) */
#define MEMSIZE (64ULL * 1024 * 1024 * 1024)

/* size of scan area (fits into CPU cache?)

   Apple M1 Pro CPU (try SCANSIZE 16 KB vs. 32 MB):
   - L1 Data Cache: 64 KB
   - L2 Cache:       4 MB
*/
#define SCANSIZE (32 * 1024 * 1024)

/* scan the memory, do pseudo work */
int64_t scan(int64_t *mem)
{
  int64_t s = 0;

  for (size_t loop = 0; loop < MEMSIZE / SCANSIZE; loop += 1) {
    for (size_t i = 0; i < SCANSIZE / sizeof(int64_t); i += 1) {
      s += mem[i];
    }
  }

  return s;
}

int main()
{
  int64_t *area;
  int64_t s;

  struct timeval t0, t1;
  unsigned long duration;

  /* make sure that we can represent large memory sizes */
  assert(sizeof(MEMSIZE) >= 8);

  /* allocate scan area */
  area = (int64_t*)malloc(SCANSIZE);
  assert(area);

  gettimeofday(&t0, NULL);
  s = scan(area);
  gettimeofday(&t1, NULL);

  duration = MICROSECS(t1) - MICROSECS(t0);
  printf("time: %luμs (result: %lld)\n", duration, s);

  return 0;
}
