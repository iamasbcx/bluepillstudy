// Simple command-line kernel monitor useful for
// controlling the kernel and exploring the system interactively.

#include <include/stdio.h>
#include <include/string.h>
#include <include/memlayout.h>
#include <include/assert.h>
#include <include/x86.h>

#include <kernel/console.h>
#include <kernel/monitor.h>
#include <kernel/kdebug.h>
#include <kernel/trap.h>

#include <mm/pmap.h>

#define CMDBUF_SIZE	80	// enough for one VGA text line

struct Command {
	const char *name;
	const char *desc;
	// return -1 to force monitor to exit
	int (*func)(int argc, char** argv, struct Trapframe* tf);
};

static struct Command commands[] = {
	{ "help", "Display this list of commands", mon_help },
	{ "kerninfo", "Display information about the kernel", mon_kerninfo },
	{ "backtrace", "Display information about the stack", mon_backtrace },
	{ "exit", "Exit from a breakpoint kernel monitor", mon_exit },
};
#define NCOMMANDS (int) (sizeof(commands)/sizeof(commands[0]))



/***** Implementations of basic kernel monitor commands *****/

int
mon_help(int argc, char **argv, struct Trapframe *tf)
{
	int i;

	for (i = 0; i < NCOMMANDS; i++)
		cprintf("%s - %s\n", commands[i].name, commands[i].desc);
	return 0;
}

int
mon_kerninfo(int argc, char **argv, struct Trapframe *tf)
{
	extern char _start[], etext[], edata[], end[];

	cprintf("Special kernel symbols:\n");
	cprintf("  _start %08x (virt)  %08x (phys)\n", _start, _start - KERNBASE);
	cprintf("  etext  %08x (virt)  %08x (phys)\n", etext, etext - KERNBASE);
	cprintf("  edata  %08x (virt)  %08x (phys)\n", edata, edata - KERNBASE);
	cprintf("  end    %08x (virt)  %08x (phys)\n", end, end - KERNBASE);
	cprintf("Kernel executable memory footprint: %dKB\n",
		(end-_start+1023)/1024);
	return 0;
}

// modified by zhumin
#define 	FUNC_NAME_MAX_LEN 	100
int
mon_backtrace(int argc, char **argv, struct Trapframe *tf)
{
	// Your code here.
	uint32_t ebp;
	uint32_t eip;
	uint32_t args[4];
	uint32_t LineNum = 0;
	struct Eipdebuginfo info;
	char 	func_name[FUNC_NAME_MAX_LEN];
	int32_t i = 0;

		cprintf("Stack backtrace:\n");

		ebp = read_ebp();

	do{
		eip = *((uint32_t *)(ebp + 4));

		for(i=0; i<4; i++) { 	// Read four pushed elements before call.
					args[i] = *((uint32_t *)(ebp + 8 + 4*i));
		}//for

		cprintf("  %d: ebp %08x  eip %08x  args %08x %08x %08x %08x\n", \
						LineNum++, ebp, eip, args[0], args[1], args[2], args[3]);

		debuginfo_eip((uintptr_t)eip,&info);

		// Translate calling function's name.
		for(i=0; i<info.eip_fn_namelen && i<FUNC_NAME_MAX_LEN; i++ ) {
			func_name[i] = info.eip_fn_name[i];
		}//for
		func_name[i] = '\0';
		// Print debug info.
		cprintf("      %s:%x: %s+%2x (%d arg)\n",info.eip_file, info.eip_line, \
						func_name, eip-info.eip_fn_addr, info.eip_fn_narg);

			ebp = *((uint32_t *)ebp);

		}while(ebp != 0);
	return 0;
}

/* Add the "exit" command to the kernel monitor, which can exit
 * a breakpoint kernel monitor.
 * by zhumin in 2009-5-16
 */
int
mon_exit(int argc, char **argv, struct Trapframe *tf)
{
	if(tf == NULL){
		cprintf("exit: Can't use in the common kernel monitor\n");
		return 0;
	}
	else {
		switch(tf->tf_trapno){
		case T_BRKPT:
			asm volatile("jmp %%eax" :: "a" (tf->tf_eip));
			break;
		default:
			cprintf("exit: Can't use in the unhandled trap!\n");
			break;
		}
	}
	return 0;
}

/***** Kernel monitor command interpreter *****/

#define WHITESPACE "\t\r\n "
#define MAXARGS 16

static int
runcmd(char *buf, struct Trapframe *tf)
{
	int argc;
	char *argv[MAXARGS];
	int i;

	// Parse the command buffer into whitespace-separated arguments
	argc = 0;
	argv[argc] = 0;
	while (1) {
		// gobble whitespace
		while (*buf && strchr(WHITESPACE, *buf))
			*buf++ = 0;
		if (*buf == 0)
			break;

		// save and scan past next arg
		if (argc == MAXARGS-1) {
			cprintf("Too many arguments (max %d)\n", MAXARGS);
			return 0;
		}
		argv[argc++] = buf;
		while (*buf && !strchr(WHITESPACE, *buf))
			buf++;
	}
	argv[argc] = 0;

	// Lookup and invoke the command
	if (argc == 0)
		return 0;
	for (i = 0; i < NCOMMANDS; i++) {
		if (strcmp(argv[0], commands[i].name) == 0)
			return commands[i].func(argc, argv, tf);
	}
	cprintf("Unknown command '%s'\n", argv[0]);
	return 0;
}

void
monitor(struct Trapframe *tf)
{
	char *buf;

	// The 'make grade' script depends on the following printout, so don't
	// remove it.
	cprintf("Welcome to the Zion Virtual Machine monitor!\n");
	cprintf("Type 'help' for a list of commands.\n");

	if (tf != NULL)
		print_trapframe(tf);

	while (1) {
		buf = readline("Zion> ");
		if (buf != NULL)
			if (runcmd(buf, tf) < 0)
				break;
	}
}
