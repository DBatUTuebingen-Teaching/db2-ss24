#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <assert.h>
#include <stdint.h>

/* path to BAT's tail file */
#define TAIL "/Users/grust/DB2/course/MonetDB/data/scratch/bat/03/331.tail"


/* scan the tail file (assuming it is of type int, column name 'a') */
void scan_tail(int32_t *tail, off_t size)
{
  for (off_t i = 0; i < size / sizeof(int32_t); i += 1) {
    printf("row #%lld: a = %d\n", i, tail[i]);
  }
}


/* mmap file at ‹path›, return address and ‹size› of memory map */
void* mmap_file(char *path, off_t *size)
{
  int fd;
  struct stat status;
  void *map;

  fd = open(path, O_RDONLY);
  assert(fd >= 0);
  assert(stat(path, &status) == 0);
  *size = status.st_size;

  map = mmap(NULL, *size, PROT_READ, MAP_SHARED, fd, 0);
  assert(map != MAP_FAILED);

  close(fd);

  return map;
}


int main()
{
  off_t tail_size;
  void *tail_map;

  /* map tail file into memory */
  tail_map = mmap_file(TAIL, &tail_size);

  scan_tail(tail_map, tail_size);

  return 0;
}
