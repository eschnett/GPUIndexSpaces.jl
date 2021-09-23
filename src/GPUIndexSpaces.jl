module GPUIndexSpaces

using OrderedCollections

################################################################################

const Code = Union{Expr,Number,Symbol}

# Bit access helpers
getbit(expression::AbstractString, i::Int) = "(($expression) >> $i) & 1"
setbit(expression::AbstractString, i::Int) = "($expression) << $i"

struct BitMap
    srcbit::Int
    dstbit::Int
    dist::Int
    BitMap(srcbit::Int, dstbit::Int) = new(srcbit, dstbit, dstbit - srcbit)
end
function movebits(expression::Code, bitmap::Vector{BitMap}, expression_mask::Integer=0)
    expression_mask = UInt(expression_mask)
    # Assert all sources are unique
    @assert length(Set(bm.srcbit for bm in bitmap)) == length(bitmap)
    distances = Set(bm.dist for bm in bitmap)
    exprs = Expr[]
    for distance in sort!(collect(distances))
        expr = expression
        bits = Int[bm.srcbit for bm in bitmap if bm.dist == distance]
        @assert !isempty(bits)
        mask = sum(UInt(1) << bit for bit in bits)
        @assert mask ≠ 0
        if expression_mask ≠ 0
            @assert mask | expression_mask == expression_mask
        end
        if mask ≠ expression_mask
            expr = :(expr & $mask)
        end
        if distance < 0
            expr = :($expr >>> $(UInt(-distance)))
        elseif distance > 0
            expr = :($expr << $(UInt(distance)))
        else
            # do nothing
        end
        push!(exprs, expr)
    end
    @assert !isempty(exprs)
    if length(exprs) == 1
        expr = exprs[1]
    else
        expr = :(+($(exprs...)))
    end
    return expr::Expr
end

################################################################################

export Index
struct Index{Tag}
    bit::Int
end
function Base.isless(i1::Index{T1}, i2::Index{T2}) where {T1,T2}
    T1 < T2 && return true
    T1 > T2 && return false
    return i1.bit < i2.bit
end

export tag, bit
tag(::Index{Tag}) where {Tag} = Tag
bit(i::Index) = i.bit

Base.show(io::IO, i::Index) = print(io, tag(i), ".", bit(i))

export SIMD, Register, Thread, Warp
const SIMD = Index{:SIMD}
const Register = Index{:Register}
const Thread = Index{:Thread}
const Warp = Index{:Warp}
# const Loop = Index{:Loop}

const max_warp_bits = 5
const max_thread_bits = 5

export Memory
const Memory = Index{:Memory}

export Mapping
struct Mapping
    mapping::Dict{Index,Index}
    function Mapping(mapping::Dict)
        # Ensure mapping is injective
        @assert length(Set(values(mapping))) == length(mapping)
        return new(mapping)
    end
end
Base.getindex(f::Mapping, i::Index) = f.mapping[i]

Base.inv(f::Mapping) = Mapping(Dict(v => k for (k, v) in f.mapping))
Base.:(∘)(g::Mapping, f::Mapping) = Mapping(Dict(k => g[v] for (k, v) in f.mapping))

################################################################################

export AbstractStep, inname, outname, inmap, outmap, expression
abstract type AbstractStep end
description(::AbstractStep) = error("undefined")
inname(::AbstractStep) = error("undefined")
outname(::AbstractStep) = error("undefined")
inmap(::AbstractStep) = error("undefined")
outmap(::AbstractStep) = error("undefined")
expression(::AbstractStep) = error("undefined")

function Base.show(io::IO, step::AbstractStep)
    println(io, "# $(description(step))")
    println(io, "#   Input: $(inname(step))")
    println(io, "#   Output: $(outname(step))")
    println(io, "#   Input mapping:")
    for (k, v) in sort!(OrderedDict(inmap(step).mapping))
        println(io, "#     $k => $v")
    end
    println(io, "#   Output mapping:")
    for (k, v) in sort!(OrderedDict(outmap(step).mapping))
        println(io, "#     $k => $v")
    end
    #STRING return println(io, join(expression(step), "\n"))
    return println(io, expression(step))
end

export Step
struct Step <: AbstractStep
    description::String
    inname::Symbol
    outname::Symbol
    inmap::Mapping
    outmap::Mapping
    #STRING expression::Vector{String}
    expression::Expr
end
description(step::Step) = step.description
inname(step::Step) = step.inname
outname(step::Step) = step.outname
inmap(step::Step) = step.inmap
outmap(step::Step) = step.outmap
expression(step::Step) = step.expression

export Id
struct Id <: AbstractStep
    mapping::Mapping
    name::Symbol
end
description(step::Id) = "No-op"
inname(step::Id) = step.name
outname(step::Id) = step.name
inmap(step::Id) = step.mapping
outmap(step::Id) = step.mapping
#STRING expression(step::Id) = []
expression(step::Id) = quote end

export Seq
struct Seq <: AbstractStep
    step1::AbstractStep
    step2::AbstractStep
    function Seq(step1::AbstractStep, step2::AbstractStep)
        @assert outname(step1) == inname(step2)
        @assert outmap(step1) == inmap(step2)
        return new(step1, step2)
    end
end
description(step::Seq) = join([description(step.step1), description(step.step2)], "; ")
inname(step::Seq) = inname(step.step1)
outname(step::Seq) = outname(step.step2)
inmap(step::Seq) = inmap(step.step1)
outmap(step::Seq) = outmap(step.step2)
#STRING expression(step::Seq) = [expression(step.step1); expression(step.step2)]
expression(step::Seq) = quote
    $(expression(step.step1))
    $(expression(step.step2))
end

################################################################################

#STRING export prelude
#STRING prelude() = """
#STRING __device__ __forceinline__ int8_t get_int8_0(int x) { return (uint8_t)x; }
#STRING __device__ __forceinline__ int8_t get_int8_1(int x) { return (uint8_t)(x >> 8); }
#STRING __device__ __forceinline__ int8_t get_int8_2(int x) { return (uint8_t)(x >> 16); }
#STRING __device__ __forceinline__ int8_t get_int8_4(int x) { return (uint8_t)(x >> 24); }
#STRING 
#STRING __device__ __forceinline__ int assemble_int8(int8_t x0, int8_t x1, int8_t x2, int8_t x3) {
#STRING   return (unsigned)(uint8_t)x0 | ((unsigned)(uint8_t)x1 << 8) | ((unsigned)(uint8_t)x2 << 16) | ((unsigned)(uint8_t)x3 << 24);
#STRING }
#STRING 
#STRING __device__ __forceinline__ int16_t get_int16_0(int x) { return (uint16_t)x; }
#STRING __device__ __forceinline__ int16_t get_int16_1(int x) { return (uint16_t)(x >> 16); }
#STRING 
#STRING __device__ __forceinline__ int assemble_int16(int16_t x0, int16_t x1) {
#STRING   return (unsigned)(uint16_t)x0 | ((unsigned)(uint16_t)x1 << 16);
#STRING }
#STRING """

get_int8_0(x::Int32) = x % Int8
get_int8_1(x::Int32) = (x >>> 8) % Int8
get_int8_2(x::Int32) = (x >>> 16) % Int8
get_int8_3(x::Int32) = (x >>> 24) % Int8

function assemble_int8(x0::Int8, x1::Int8, x2::Int8, x3::Int8)
    return ((x0 % Uint8 % UInt32) | ((x1 % Uint8 % UInt32) << 8) | ((x2 % Uint8 % UInt32) << 16) | ((x3 % Uint8 % UInt32) << 32)) %
           Int32
end

get_int16_0(x::Int32) = x % Int16
get_int16_1(x::Int32) = (x >>> 16) % Int16

assemble_int16(x0::Int16, x1::Int16) = ((x0 % Uint16 % UInt32) | ((x1 % Uint16 % UInt32) << 16)) % Int32

export constant
function constant(outname::Symbol, outmap::Mapping, value::Code)
    registers = [v.bit for (k, v) in outmap.mapping if v isa Register]
    register_bits = isempty(registers) ? 0 : maximum(registers) + 1
    simds = [v.bit for (k, v) in outmap.mapping if v isa SIMD]
    simd_bits = isempty(simds) ? 0 : maximum(simds) + 1
    stmts = Expr[]
    for r in 0:((1 << register_bits) - 1)
        rname = register_bits == 0 ? "" : "$r"
        if simd_bits == 0
            push!(stmts, quote
                      $(Symbol(outname, rname)) = $value
                  end)
        elseif simd_bits == 1
            push!(stmts, quote
                      $(Symbol(outname, rname)) = assemble_int16($value, $value)
                  end)
        elseif simd_bits == 2
            push!(stmts, quote
                      $(Symbol(outname, rname)) = assemble_int8($value, $value, $value, $value)
                  end)
        else
            @assert false
        end
    end
    return Step("Set to constant", Symbol("(nothing)"), outname, Mapping(Dict()), outmap, quote
                    $(stmts...)
                end)
end

export assign
function assign(inname::Symbol, outname::Symbol, inmap::Mapping)
    registers = [v.bit for (k, v) in inmap.mapping if v isa Register]
    register_bits = isempty(registers) ? 0 : maximum(registers) + 1
    stmts = Expr[]
    for r in 0:((1 << register_bits) - 1)
        rname = register_bits == 0 ? "" : "$r"
        push!(stmts, quote
                  $(Symbol(outname, rname)) = $(Symbol(inname, rname))
              end)
    end
    return Step("Assign to variable", inname, outname, inmap, inmap, quote
                    $(stmts...)
                end)
end

export apply
function apply(inname::Symbol, outname::Symbol, fun::Function, inmap::Mapping)
    registers = [v.bit for (k, v) in inmap.mapping if v isa Register]
    register_bits = isempty(registers) ? 0 : maximum(registers) + 1
    simds = [v.bits for (k, v) in inmap.mapping if v isa SIMD]
    simd_bits = isempty(simds) ? 0 : maximum(simds) + 1
    stmts = Expr[]
    for r in 0:((1 << register_bits) - 1)
        rname = register_bits == 0 ? "" : "$r"
        if simd_bits == 0
            result = push!(stmts, quote
                               $(Symbol(outname, rname)) = $(fun(Symbol(inname, rname))::Code)
                           end)
        elseif simd_bits == 1
            push!(stmts, "const int16_t $outname$(rname)_in0 = get_int16_0($inname$rname);")
            push!(stmts, "const int16_t $outname$(rname)_in1 = get_int16_1($inname$rname);")
            funcall0 = fun("$outname$(rname)_in0")
            funcall1 = fun("$outname$(rname)_in1")
            push!(stmts, "const int16_t $outname$(rname)_out0 = $funcall0;")
            push!(stmts, "const int16_t $outname$(rname)_out1 = $funcall1;")
            push!(stmts, "const int $outname$rname = assemble_int16($outname$(rname)_out0, $outname$(rname)_out1);")
        elseif simd_bits == 2
            push!(stmts, "const int8_t $outname$(rname)_in0 = get_int8_0($inname$rname);")
            push!(stmts, "const int8_t $outname$(rname)_in1 = get_int8_1($inname$rname);")
            push!(stmts, "const int8_t $outname$(rname)_in2 = get_int8_2($inname$rname);")
            push!(stmts, "const int8_t $outname$(rname)_in3 = get_int8_3($inname$rname);")
            funcall0 = fun("$outname$(rname)_in0")
            funcall1 = fun("$outname$(rname)_in1")
            funcall2 = fun("$outname$(rname)_in2")
            funcall3 = fun("$outname$(rname)_in3")
            push!(stmts, "const int8_t $outname$(rname)_out0 = $funcall0;")
            push!(stmts, "const int8_t $outname$(rname)_out1 = $funcall1;")
            push!(stmts, "const int8_t $outname$(rname)_out2 = $funcall2;")
            push!(stmts, "const int8_t $outname$(rname)_out3 = $funcall3;")
            push!(stmts,
                  "const int $outname$rname = assemble_int8($outname$(rname)_out0, $outname$(rname)_out1, $outname$(rname)_out2, $outname$(rname)_out3);")
        else
            @assert false
        end
    end
    return Step("Apply function", inname, outname, inmap, inmap, quote
                    $(stmts...)
                end)
end

export load
function load(memname::Symbol, outname::Symbol, memmap::Mapping, outmap::Mapping)
    memories = [v.bit for (k, v) in outmap.mapping if v isa Memory]
    memory_bits = isempty(memories) ? 0 : maximum(memories) + 1
    warps = [v.bit for (k, v) in outmap.mapping if v isa Warp]
    warp_bits = isempty(warps) ? 0 : maximum(warps) + 1
    threads = [v.bit for (k, v) in outmap.mapping if v isa Thread]
    thread_bits = isempty(threads) ? 0 : maximum(threads) + 1
    registers = [v.bit for (k, v) in outmap.mapping if v isa Register]
    register_bits = isempty(registers) ? 0 : maximum(registers) + 1
    simds = [v.bit for (k, v) in outmap.mapping if v isa SIMD]
    simd_bits = isempty(simds) ? 0 : maximum(simds) + 1
    memmap_inv_inmap = memmap ∘ inv(outmap)
    stmts = Expr[]
    for reg in 0:((1 << register_bits) - 1)
        rname = register_bits == 0 ? "" : "$reg"
        if simd_bits == 0
            expressions = Expr[]
            # TODO: Convert to `size_t`
            # TODO: This assumes a memory layout in `int`s, not bytes
            push!(expressions,
                  movebits(:(threadIdx.y), [BitMap(w, (memmap_inv_inmap[Warp(w)]::Memory).bit) for w in 0:(warp_bits - 1)],
                           (1 << max_warp_bits) - 1))
            push!(expressions,
                  movebits(:(threadIdx.x), [BitMap(t, (memmap_inv_inmap[Thread(t)]::Memory).bit) for t in 0:(thread_bits - 1)],
                           (1 << max_thread_bits) - 1))
            push!(expressions,
                  movebits(reg, [BitMap(r, (memmap_inv_inmap[Register(r)]::Memory).bit) for r in 0:(register_bits - 1)]))
            if length(expressions) == 1
                expression = expressions[1]
            else
                expression = :(+($(expressions...)))
            end
            push!(stmts, quote
                      $(Symbol(outname, rname)) = $memname[$expression]
                  end)
        else
            @assert false
        end
    end
    return Step("Load from memory", Symbol("(nothing)"), outname, Mapping(Dict()), outmap, quote
                    $(stmts...)
                end)
end

export store
function store(inname::Symbol, memname::Symbol, inmap::Mapping, memmap::Mapping)
    warps = [v.bit for (k, v) in inmap.mapping if v isa Warp]
    warp_bits = isempty(warps) ? 0 : maximum(warps) + 1
    threads = [v.bit for (k, v) in inmap.mapping if v isa Thread]
    thread_bits = isempty(threads) ? 0 : maximum(threads) + 1
    registers = [v.bit for (k, v) in inmap.mapping if v isa Register]
    register_bits = isempty(registers) ? 0 : maximum(registers) + 1
    simds = [v.bit for (k, v) in inmap.mapping if v isa SIMD]
    simd_bits = isempty(simds) ? 0 : maximum(simds) + 1
    memories = [v.bit for (k, v) in memmap.mapping if v isa Memory]
    memory_bits = isempty(memories) ? 0 : maximum(memories) + 1
    memmap_inv_inmap = memmap ∘ inv(inmap)
    stmts = Expr[]
    for reg in 0:((1 << register_bits) - 1)
        rname = register_bits == 0 ? "" : "$reg"
        if simd_bits == 0
            expressions = Expr[]
            # TODO: Convert to `size_t`
            # TODO: This assumes a memory layout in `int`s, not bytes
            push!(expressions,
                  movebits(:(threadIdx.y), [BitMap(w, (memmap_inv_inmap[Warp(w)]::Memory).bit) for w in 0:(warp_bits - 1)],
                           (1 << max_warp_bits) - 1))
            push!(expressions,
                  movebits(:(threadIdx.x), [BitMap(t, (memmap_inv_inmap[Thread(t)]::Memory).bit) for t in 0:(thread_bits - 1)],
                           (1 << max_thread_bits) - 1))
            push!(expressions,
                  movebits(reg, [BitMap(r, (memmap_inv_inmap[Register(r)]::Memory).bit) for r in 0:(register_bits - 1)]))
            if length(expressions) == 1
                expression = expressions[1]
            else
                expression = :(+($(expressions...)))
            end
            push!(stmts, quote
                      $memname[$expression] = $(Symbol(outname, rname))
                  end)
        else
            @assert false
        end
    end
    return Step("Store to memory", inname, inname, inmap, inmap, quote
                    $(stmts...)
                end)
end

function permute_simd(inmap::Mapping, perm::Mapping)
    simd03(i) = i isa SIMD && 0 ≤ i.bit < 2
    @assert length(perm) == 4
    @assert all(simd03(k) && simd03(v) for (k, v) in perm)
    for (k, v) in inmap
        k isa SIMD && @assert 0 ≤ k.bit < 2
        v isa SIMD && @assert 0 ≤ v.bit < 2
    end
    outmap = copy(inmap)
    for i in 0:3
        outmap[SIMD(i)] = inmap[SIMD(perm[SIMD(i)])]
    end
    bytes = Array{Int}(undef, 4)
    for i in 0:3
        bits = [(i >> n) & 1 for n in 0:1]
        newbits = [bits[perm[SIMD(n)].bit + 1] for n in 0:1]
        bytes[i + 1] = sum(newbits[n + 1] << n for n in 0:1)
    end
    s = sum(bytes[i + 1] << (4 * i) for i in 0:3)
    @assert s ∈ [0x3210, 0x3120]
    return Step("Permute SIMD entries", inmap, outmap, ["__byte_perm(r, 0, 0x$(string(s; base=16)));"])
end

function permute_thread(inmap::Mapping, perm::Mapping)
    thread04(i) = i isa Thread && 0 ≤ i.bit < 5
    @assert length(perm) == 5
    @assert all(thread04(k) && thread04(v) for (k, v) in perm)
    for (k, v) in inmap
        k isa Thread && @assert 0 ≤ k.bit < 5
        v isa Thread && @assert 0 ≤ v.bit < 5
    end
    outmap = copy(inmap)
    for i in 0:4
        outmap[Thread(i)] = inmap[Thread(perm[Thread(i)])]
    end
    sources = String[]
    for i in 0:4
        j = perm[Thread(i)].bit
        push!(sources, setbit(getbit("threadIdx.x", i), j))
    end
    source = "(" * join(sources, ") | (") * ")"
    return Step("Permute threads", inmap, outmap, ["__shfl_sync(~0U, r, $source);"])
end

# convert_int8_to_int16 (with more registers)
# convert_int16_to_int32 (with more registers)
# convert_int8_to_int32 (with more registers)
# convert_int16_to_int8 (with fewer registers)
# convert_int32_to_int16 (with fewer registers)
# convert_int32_to_int8 (with fewer registers)
# TODO: Implement the 8- and 16-bit `apply` above this way.

function permute_thread_register(inmap::Mapping, thread::Int, register::Int)
    @assert 0 ≤ thread < 5
    @assert 0 ≤ register < 1
    for (k, v) in inmap
        k isa Thread && @assert 0 ≤ k.bit < 5
        v isa Thread && @assert 0 ≤ v.bit < 5
        k isa Register && @assert 0 ≤ k.bit < 1
        v isa Register && @assert 0 ≤ v.bit < 1
    end
    outmap = copy(inmap)
    outmap[Thread(thread)] = inmap[Register(register)]
    outmap[Register(register)] = inmap[Thread(thread)]
    return Step("Permute thread and regsiter", inmap, outmap,
                ["{";
                 "  const int bit = 1 << thread;";
                 "  const bool flag = (threadIdx.x & bit) != 0;";
                 "  const int src = flag ? r[0] : r[1];";
                 "  const int dst = __shfl_xor_sync(~0U, src, bit);";
                 "  flag ? r[0] = dst : r[1] = dst;";
                 "}"])
end

end
