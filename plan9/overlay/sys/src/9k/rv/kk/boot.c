/*
 * The first user program on the Kakao SOC.  It takes the place of
 * ../boot's boot, which asks where the root file system is and connects
 * to it: this machine's root is in the kernel (kkroot.tar) and kkinit
 * puts it in a ramfs.  All that is done here is what rc cannot do before
 * it runs.
 */
#include <u.h>
#include <libc.h>

void
main(void)
{
	static char *argv[] = { "rc", "-m", "/boot/rcmain", "/boot/kkinit", nil };
	int fd;

	open("#c/cons", OREAD);
	open("#c/cons", OWRITE);
	open("#c/cons", OWRITE);
	/* nobody has said who owns this machine; it needs an owner */
	fd = open("#c/hostowner", OWRITE);
	if(fd >= 0){
		write(fd, "glenda", 6);
		close(fd);
	}
	bind("#ec", "/env", MREPL);
	bind("#e", "/env", MBEFORE|MCREATE);
	bind("#p", "/proc", MREPL);
	bind("#s", "/srv", MREPL|MCREATE);
	bind("/boot", "/bin", MAFTER);
	exec("/boot/rc", argv);
	print("boot: can't exec /boot/rc: %r\n");
	for(;;)
		sleep(1000);
}
