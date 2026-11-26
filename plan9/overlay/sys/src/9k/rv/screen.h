/*
 * From ../../9/bcm/screen.h, without the Pi's LCD.
 *
 * The draw and mouse devices of ../../9/port ask conf.monitor whether
 * there is a screen; the 9k kernels have no conf, so here is one with
 * that in it.
 */
typedef struct Kkconf Kkconf;
struct Kkconf {
	int	monitor;
};
extern Kkconf conf;

typedef struct Cursor Cursor;
typedef struct Cursorinfo Cursorinfo;

struct Cursorinfo {
	Cursor;
	Lock;
};

/* devmouse.c */
extern void mousetrack(int, int, int, int);
extern Point mousexy(void);

extern void mouseaccelerate(int);
extern int m3mouseputc(Queue*, int);
extern int m5mouseputc(Queue*, int);
extern int mouseputc(Queue*, int);

extern Cursorinfo cursor;
extern Cursor arrow;

/* mouse.c */
extern void mousectl(Cmdbuf*);
extern void mouseresize(void);

/* screen.c */
extern void	blankscreen(int);
extern void	flushmemscreen(Rectangle);
extern uchar*	attachscreen(Rectangle*, ulong*, int*, int*, int*);
extern int	cursoron(int);
extern void	cursoroff(int);
extern void	setcursor(Cursor*);
extern Rectangle physgscreenr;	/* actual monitor size */
extern Memimage *gscreen;

/* devdraw.c */
extern void	deletescreenimage(void);
extern void	resetscreenimage(void);
extern int		drawhasclients(void);
extern ulong	blanktime;
extern void	setscreenimageclipr(Rectangle);
extern void	drawflush(void);
extern int drawidletime(void);
extern void	drawblankscreen(int);
extern QLock	drawlock;

#define ishwimage(i)	1		/* for ../port/devdraw.c */

