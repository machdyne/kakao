/*
 * What the Kakao port takes from the device tree the firmware hands the
 * kernel (kkfdt.c).
 */
typedef struct Vslot Vslot;
struct Vslot {			/* a virtio-mmio register page */
	uintptr	pa;
	int	irq;		/* its source at the PLIC */
};

typedef struct Kkfb Kkfb;
struct Kkfb {			/* a simple-framebuffer node */
	uintptr	pa;
	uint	width;
	uint	height;
	uint	stride;		/* bytes a line */
	uint	depth;		/* 16 (r5g6b5) or 32 (x8r8g8b8); 0 if neither */
	uintptr	ctrl;		/* the Kakao SOC's: its registers, see screen.c */
};

enum {
	Maxvslot = 8,
};

extern Vslot	kkvslots[Maxvslot];
extern int	nkkvslot;
extern int	kkfdtok;	/* a device tree was found and read */
extern uintptr	kkfdtpa;
extern uintptr	kkfwcfg;
extern Kkfb	kkfb;

void	fdtconf(void);
