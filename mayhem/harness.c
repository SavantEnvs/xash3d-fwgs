// Fuzz entry: loads libxash.so and forwards to the engine's Fuzz_<Func> hook, exactly like
// utils/run-fuzzer/run-fuzzer.c, except an empty input is skipped. Engine hooks such as
// Fuzz_Mod_LoadModel memcpy() the input into Mem_Malloc(0) == NULL, which is a harness artifact
// (UBSan nonnull-attribute), not a bug in the code under test.
//
// With -DMIN_SIZE=N, inputs shorter than N bytes are zero-padded up to N before the call. Sound_LoadMPG
// rejects anything under FRAME_SIZE (32768) bytes, while Mayhem runs libFuzzer with -max_len=8192, so
// without the padding the decoder is unreachable. Inputs of N bytes or more pass through unchanged.
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !defined LIB || !defined FUNC
#error
#endif

typedef int (*FuzzFunc)(const uint8_t *Data, size_t Size);

static void *handle = NULL;
static FuzzFunc f = NULL;

int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size);
int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size)
{
	if (Size == 0)
		return 0;

	if (!handle)
		handle = dlopen(LIB, RTLD_NOW);

	if (handle)
	{
		if (!f)
			f = (FuzzFunc)dlsym(handle, FUNC);

		if (f)
		{
#ifdef MIN_SIZE
			if (Size < MIN_SIZE)
			{
				uint8_t *padded = calloc(1, MIN_SIZE);
				int ret;

				if (!padded)
					abort();
				memcpy(padded, Data, Size);
				ret = f(padded, MIN_SIZE);
				free(padded);
				return ret;
			}
#endif
			return f(Data, Size);
		}
	}

	fprintf(stderr, "Fail: %s\n", dlerror());
	abort();
	return 0;
}
