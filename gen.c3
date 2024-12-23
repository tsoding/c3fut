// Hello Mister Zozin, I liked your video about Futures
// it inspired me to implement a different concurency primitive in c3
// you might find it interesting, maybe even usefull

// python calls them a generator
// in c# it is a coroutine

// it is the one where you yield a value suspending execution
// and you can resume it again from that point

// to implement it I allocate a seperate stack for the coroutine
// and start execuing the coroutine there
// then I use longjmp to switch between it and the original stack

import std::io;
import libc;
import std::collections::list;
import std::core::string;



def GenFn = fn void!(Generator*, any usr_data);
def GenWrapFn = fn void(GenFn, Generator*);

const int JMP_CODE_YIELD = 1;
const int JMP_CODE_FINISH = 2;
const int JMP_CODE_ERROR = 3;

// using a different type on the producer and consumer side
// means methods that should only be called by one side
// are only available on that side

// producer side
struct Generator{
    libc::JmpBuf producer;
    libc::JmpBuf consumer;
    any value;
    anyfault err;
    void* stack;
    usz stack_size;
}

// yield a value, null can be used to signal no value is ready yet
fn void Generator.yield(Generator *g, any value){
    if(!libc::setjmp(&g.producer)){
        g.value = value;
        libc::longjmp(&g.consumer, JMP_CODE_YIELD);
    }
}

// early return from coroutine
fn void Generator.finish(Generator *g){
    libc::longjmp(&g.consumer, JMP_CODE_FINISH);
}

fn void Generator.error(Generator *g, anyfault excuse){
    g.err = excuse;
    libc::longjmp(&g.consumer, JMP_CODE_ERROR);
}

// consumer side
struct Coroutine{ Generator g; }


fn any! Coroutine.next(Coroutine *c){
    if(c.done()) return null;
    Generator *g = &c.g;
    int stat = libc::setjmp(&g.consumer);
    if(!stat){
        libc::longjmp(&g.producer, 1);
    }

    switch(stat){
        case JMP_CODE_YIELD:
            return g.value;
        case JMP_CODE_FINISH:
            c.uninit();
            return null;
        case JMP_CODE_ERROR:
            anyfault f = g.err;
            c.uninit();
            return f?;
        default:
            $$unreachable();
    }
}


fn void Coroutine.init(
    Coroutine *co,
    GenFn func,
    any usr_data,
    usz stack_size = 0x100000
){
    Generator *gen = &co.g;

    // consider using mmap here
    // that way a stack overflow in the generator has a high chance of segfaulting instead of corrupting temp allocator data
    // don't forget to change the coresponding free
    void* new_stack = mem::calloc_aligned(stack_size, 16);

    gen.stack_size = stack_size;
    gen.stack = new_stack;
    gen.value = usr_data;

    // the stack grows down and needs to be aligned
    void* stack_start = (void*)((char*)new_stack + stack_size - 8);

    if(!libc::setjmp(&gen.consumer)){
        (fn void (void* new_stack, GenFn func, Generator* gen){
            // we don't call the user function immediatly but a wrapper
            // to finish setup on the second stack and cleanup properly
            GenWrapFn gen_wrap_fn = &gen_wrap;
            asm{
                // change stack pointer
                movq $rsp, new_stack;

                // pass arguments via calling convention
                movq $rdi, func;
                movq $rsi, gen;
                // jmp doesn't seem to be implemented, so we push and ret
                movq $rax, gen_wrap_fn;
                pushq $rax;
                ret;
            };
            $$unreachable();
        })(stack_start, func, gen);
        $$unreachable();
    }
}
fn void gen_wrap(GenFn gen_fn, Generator *gen){
    if(!libc::setjmp(&gen.producer)){
        libc::longjmp(&gen.consumer, 1);
    }
    if(catch excuse = gen_fn(gen, gen.value)){
        gen.error(excuse);
        $$unreachable();
    }
    gen.finish();
    // there is no return adress on the stack, make sure we don't return
    $$unreachable();
}

// clean up a Coroutine, before it is done
// if it finishes uninit may be called but is not needed
fn void Coroutine.uninit(Coroutine *co){
    Generator *gen = &co.g;
    if(gen.stack){
        libc::free(gen.stack);
    }
    *gen = Generator{};
}

fn bool Coroutine.done(Coroutine *co){
    return co.g.stack == null;
}


// example usage


fn void print_interleaved(Generator *gen, String s){
    for(isz i = 0; i < s.len; i++){
        io::printf("%c", s[i]);
        gen.yield(null);
    }
}


fn void main(){
    List(<Coroutine*>) routines;

    int data1 = 7;
    int data2 = 7;
    Coroutine *co = mem::temp_new(Coroutine);
    co.init(fn void! (Generator *gen, any data){
        // look, no then spam!
        print_interleaved(gen, "Hello World!");
        io::printn("a");
        gen.yield(null);
        io::printn("b");
        gen.yield(null);
        io::printn("c");
        gen.yield(null);
        io::printn("d");
    }, &data1);
    routines.push(co);

    co = mem::temp_new(Coroutine);
    co.init(fn void! (Generator *gen, any data){
        print_interleaved(gen, "___________\n");
        int n = 0;
        switch(data){ case int: n = *data; }

        // control flow constructs just work
        for(int i = 0; i < n; i++){
            io::printfn("i: %d", i);
            gen.yield(&i);
        }
    }, &data2);
    routines.push(co);

    io::printn("Hello");

    while(1){
        foreach(Coroutine *c : routines){
            any val = c.next()!!;
        }
        bool done = true;
        foreach(Coroutine *c : routines){
            if(!c.done()) done = false;
        }
        if(done) break;
    }

}

// comparison with futures:
// Pros:
//  - syntactically nicer
//  - it is easier to port synchronous code
//     just make the io primitives yield instead of blocking
//     and pass a Generator around as a parameter
// Cons:
//  - implementation is architecture specific
//  - needs an upper bound for couroutine stack usage
