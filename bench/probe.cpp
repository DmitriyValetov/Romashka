#include <sys/attr.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <cerrno>
int main(int argc,char**argv){
  const char*path = argc>1?argv[1]:"/usr/bin";
  int fd=open(path,O_RDONLY|O_DIRECTORY);
  if(fd<0){perror("open");return 1;}
  struct attrlist al; memset(&al,0,sizeof al);
  al.bitmapcount=ATTR_BIT_MAP_COUNT;
  al.commonattr=ATTR_CMN_RETURNED_ATTRS|ATTR_CMN_NAME|ATTR_CMN_OBJTYPE|ATTR_CMN_FILEID;
  al.fileattr=ATTR_FILE_LINKCOUNT|ATTR_FILE_TOTALSIZE|ATTR_FILE_ALLOCSIZE;
  static char buf[64*1024];
  int n=getattrlistbulk(fd,&al,buf,sizeof buf,0);
  printf("n=%d errno=%s buf=%p\n",n,strerror(errno),(void*)buf);
  if(n<=0)return 0;
  char*p=buf;
  for(int i=0;i<n && i<4;i++){
    unsigned rl; memcpy(&rl,p,4);
    printf("--- rec %d reclen=%u off=%td\n",i,rl,(p-buf));
    printf("    raw: "); for(unsigned k=0;k<rl && k<72;k++) printf("%02x",(unsigned char)p[k]); printf("\n");
    attribute_set_t ret; memcpy(&ret,p+4,sizeof ret);
    printf("    common=0x%08x file=0x%08x dir=0x%08x\n",ret.commonattr,ret.fileattr,ret.dirattr);
    p+=rl;
  }
  return 0;
}
