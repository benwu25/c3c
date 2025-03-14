// Copyright (c) 2025 Christoffer Lerno. All rights reserved.
// Use of this source code is governed by the MIT license
// a copy of which can be found in the LICENSE_STDLIB file.
module std::core::runtime;
import std::core::test @public;
import libc, std::time, std::io, std::sort;
import std::os::env;

def TestFn = fn void!() @if($$OLD_TEST);
def TestFn = fn void() @if(!$$OLD_TEST);

TestContext* test_context @private;

struct TestContext
{
	JmpBuf buf;
	// Allows filtering test cased or modules by substring, e.g. 'foo::', 'foo::test_add'
	String test_filter;
	// Triggers debugger breakpoint when assert or test:: checks failed
	bool breakpoint_on_assert;

	// internal state
	bool assert_print_backtrace;
	bool has_ansi_codes;
	bool is_in_panic;
	String current_test_name;
	TestFn setup_fn;
	TestFn teardown_fn;

	char* error_buffer;
	usz error_buffer_capacity;
	File fake_stdout;
	File orig_stdout;
	File orig_stderr;
}

struct TestUnit
{
	String name;
	TestFn func;
}

fn TestUnit[] test_collection_create(Allocator allocator = allocator::heap())
{
	TestFn[] fns = $$TEST_FNS;
	String[] names = $$TEST_NAMES;
	TestUnit[] tests = allocator::alloc_array(allocator, TestUnit, names.len);
	foreach (i, test : fns)
	{
		tests[i] = { names[i], fns[i] };
	}
	return tests;
}

// Sort the tests by their name in ascending order.
fn int cmp_test_unit(TestUnit a, TestUnit b)
{
	usz an = a.name.len;
	usz bn = b.name.len;
	if (an > bn) @swap(a, b);
	foreach (i, ac : a.name)
	{
		char bc = b.name[i];
		if (ac != bc) return an > bn ? bc - ac : ac - bc;
	}
	return (int)(an - bn);
}

fn bool terminal_has_ansi_codes() @local
{
	@pool()
	{
		if (try v = env::get_var_temp("TERM"))
		{
			if (v.contains("xterm") || v.contains("vt100") || v.contains("screen")) return true;
		}
		$if env::WIN32 || env::NO_LIBC:
			return false;
		$else
			return io::stdout().isatty();
		$endif
	};
}

fn void test_panic(String message, String file, String function, uint line) @local
{
	if (test_context.is_in_panic) return;
	test_context.is_in_panic = true;

	unmute_output(true);
	(void)io::stdout().flush();
	if (test_context.assert_print_backtrace)
	{
		$if env::NATIVE_STACKTRACE:
    		builtin::print_backtrace(message, 0);
		$endif
	}
	io::printf("\nTest failed ^^^ ( %s:%s ) %s\n",  file, line, message);
	test_context.assert_print_backtrace = true;

	if (test_context.breakpoint_on_assert)
	{
		breakpoint();
	}

	if (test_context.teardown_fn)
	{
		test_context.teardown_fn();
	}

	test_context.is_in_panic = false;
	libc::longjmp(&test_context.buf, 1);
}

fn void mute_output() @local
{
	if (!test_context.fake_stdout.file) return;
	assert(!test_context.orig_stderr.file);
	assert(!test_context.orig_stdout.file);

	File* stdout = io::stdout();
	File* stderr = io::stderr();

	test_context.orig_stderr = *stderr;
	test_context.orig_stdout = *stdout;

	*stderr = test_context.fake_stdout;
	*stdout = test_context.fake_stdout;

	(void)test_context.fake_stdout.seek(0, Seek.SET)!!;
}

fn void unmute_output(bool has_error) @local
{
	if (!test_context.fake_stdout.file)
	{
		return;
	}
	assert(test_context.orig_stderr.file);
	assert(test_context.orig_stdout.file);

	File* stdout = io::stdout();
	File* stderr = io::stderr();

	*stderr = test_context.orig_stderr;
	*stdout = test_context.orig_stdout;
	test_context.orig_stderr.file = null;
	test_context.orig_stdout.file = null;

	usz log_size = test_context.fake_stdout.seek(0, Seek.CURSOR)!!;
	if (has_error)
	{
		io::printn(test_context.has_ansi_codes ? "[\e[0;31mFAIL\e[0m]" : "[FAIL]");
	}

	if (has_error && log_size > 0)
	{
		test_context.fake_stdout.write_byte('\n')!!;
		test_context.fake_stdout.write_byte('\0')!!;
		(void)test_context.fake_stdout.seek(0, Seek.SET)!!;

		io::printfn("\n========== TEST LOG ============");
		io::printfn("%s\n", test_context.current_test_name);
		while (try c = test_context.fake_stdout.read_byte())
		{
			if (@unlikely(c == '\0'))
			{
				// ignore junk from previous tests 
				break;
			}
			libc::putchar(c);
		}
		io::printf("========== TEST END ============");
	}
	(void)stdout.flush();
}

fn bool run_tests(String[] args, TestUnit[] tests) @private
{
	usz max_name;
	bool sort_tests = true;
	foreach (&unit : tests)
	{
		if (max_name < unit.name.len) max_name = unit.name.len;
	}
	TestContext context =
	{
		.assert_print_backtrace = true,
		.breakpoint_on_assert = false,
		.test_filter = "",
		.has_ansi_codes = terminal_has_ansi_codes(),
	};
	for (int i = 1; i < args.len; i++)
	{
		switch (args[i])
		{
			case "breakpoint":
				context.breakpoint_on_assert = true;
			case "nosort":
				sort_tests = false;
			case "noansi":
				context.has_ansi_codes = false;
			case "useansi":
				context.has_ansi_codes = true;
			case "filter":
				if (i == args.len - 1)
				{
					io::printn("Invalid arguments to test runner.");
					return false;
				}
				context.test_filter = args[i + 1];
				i++;
			default:
				io::printfn("Unknown argument: %s", args[i]);
		}
	}
	test_context = &context;

	if (sort_tests)
	{
		quicksort(tests, &cmp_test_unit);
	}

	// Buffer for hijacking the output
	$if (!env::NO_LIBC):
		test_context.fake_stdout.file = libc::tmpfile();
	$endif
	if (test_context.fake_stdout.file == null)
	{
		io::print("Failed to hijack stdout, tests will print everything");
	}

	PanicFn old_panic = builtin::panic;
	defer builtin::panic = old_panic;
	builtin::panic = &test_panic;
	int tests_passed = 0;
	int tests_skipped = 0;
	int test_count = tests.len;
	DString name = dstring::temp_with_capacity(64);
	usz len = max_name + 9;
	name.append_repeat('-', len / 2);
	name.append(" TESTS ");
	name.append_repeat('-', len - len / 2);
	io::printn(name);
	name.clear();
	foreach(unit : tests)
	{
		if (test_context.test_filter && !unit.name.contains(test_context.test_filter))
		{
			tests_skipped++;
			continue;
		}
		test_context.setup_fn = null;
		test_context.teardown_fn = null;
		test_context.current_test_name = unit.name;

		defer name.clear();
		name.appendf("Testing %s ", unit.name);
		name.append_repeat('.', max_name - unit.name.len + 2);
		io::printf("%s ", name.str_view());

		if (libc::setjmp(&context.buf) == 0)
		{
			mute_output();
			$if(!$$OLD_TEST):
				unit.func();
			$else
				if (catch err = unit.func())
				{
					io::printf("[FAIL] Failed due to: %s", err);
					continue;
				}
			$endif
			unmute_output(false); // all good, discard output


			io::printfn(test_context.has_ansi_codes ? "[\e[0;32mPASS\e[0m]" : "[PASS]");
			tests_passed++;

			if (test_context.teardown_fn)
			{
				test_context.teardown_fn();
			}
		}
	}
	io::printfn("\n%d test%s run.\n", test_count-tests_skipped, test_count > 1 ? "s" : "");

	int n_failed = test_count - tests_passed - tests_skipped;
	io::printf("Test Result: %s%s%s: ",
				test_context.has_ansi_codes ? (n_failed ? "\e[0;31m" : "\e[0;32m") : "",
				n_failed ? "FAILED" : "PASSED",
				test_context.has_ansi_codes ? "\e[0m" : "",
				);

	io::printfn("%d passed, %d failed, %d skipped.",
				tests_passed,
				n_failed,
				tests_skipped);

	// cleanup fake_stdout file
	if (test_context.fake_stdout.file) libc::fclose(test_context.fake_stdout.file);
	test_context.fake_stdout.file = null;

	return n_failed == 0;
}

fn bool default_test_runner(String[] args)
{
	@pool()
	{
		assert(test_context == null, "test suite is already running");
		return run_tests(args, test_collection_create(allocator::temp()));
	};
}

