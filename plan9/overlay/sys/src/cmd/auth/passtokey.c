/*
 * passtokey password - write the DES key the password stands for, as
 * the authentication server keeps it for a user (/mnt/keys/user/key).
 * Written for Kakao Plan 9's kkcpu; auth/changeuser is the real thing.
 */
#include <u.h>
#include <libc.h>
#include <authsrv.h>

void
main(int argc, char **argv)
{
	char key[DESKEYLEN];

	if(argc != 2){
		fprint(2, "usage: auth/passtokey password\n");
		exits("usage");
	}
	if(!passtokey(key, argv[1])){
		fprint(2, "auth/passtokey: bad password (8 characters or more)\n");
		exits("bad password");
	}
	if(write(1, key, DESKEYLEN) != DESKEYLEN)
		exits("write");
	exits(nil);
}
