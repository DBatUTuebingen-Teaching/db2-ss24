#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <assert.h>
#include <sys/time.h>
#include <stdlib.h>

#define MICROSECS(t) (1000000 * (t).tv_sec + (t).tv_usec)


/* compile via cc -O2 madvise.c -o madvise
   use `sudo purge' to clear OS buffer cache, then run:

   ./madvise 0   no madvise(... , MADV_SEQUENTIAL)
   ./madvise 1   use madvise(... , MADV_SEQUENTIAL)

*/

/*            | no madvise()  | with madvise()
 * cold cache | 8315425 μs    | 7152503μs
 */

/* file has 4627922661 bytes ≅ 4.3 GB */
#define PATH "/Users/grust/Music/iTunes/iTunes Music/Movies/01 The LEGO Batman Movie (1080p HD).m4v"

/* scan the file, do pseudo work */
int scan(char *m, off_t size)
{
  int sum = 0;

  for (off_t i = 0; i < size; i = i+1) {
    sum = sum + *(m + i);
  }

  return sum;
}

int main(int argc, char** argv)
{
  int sum;
  int fd;
  off_t size;
  void *map;
  struct stat status;

  struct timeval t0, t1;
  unsigned long duration;

  int advise = 0;    /* use madvise()? */

  /* use command line arg 0/1 to turn off/on madvise() */
  if (argc >= 2)
    advise = atoi(argv[1]);

  /* open file and determine its size in bytes */
  fd = open(PATH, O_RDONLY);
  assert(fd >= 0);
  assert(stat(PATH, &status) == 0);
  size = status.st_size;

  /* map file into memory */
  map = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
  assert(map != MAP_FAILED);

  close(fd);

  if (advise)
    /* advise the OS that file access will be sequential */
    assert(madvise(map, size, MADV_SEQUENTIAL) >= 0);

  gettimeofday(&t0, NULL);
  sum = scan(map, size);
  gettimeofday(&t1, NULL);

  duration = MICROSECS(t1) - MICROSECS(t0);
  printf("time: %luμs (did%s use madvise(), sum = %d)\n",
         duration, advise ? "" : "n't", sum);

  return 0;
}
