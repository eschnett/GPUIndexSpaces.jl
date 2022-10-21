# CHORD 8-bit baseband beamformer
# See <https://www.overleaf.com/project/6228adae742a3a2da1afe437>

using BenchmarkTools
using CUDA
using GPUIndexSpaces
using Random

################################################################################

# Kernel parameters

#UNDO const T = 32768                # number of times
const T = 128                  # number of times
const T1 = 128                  # outer time cadence
@assert T % T1 == 0
#UNDO const B = 96                    # number of beams
const B = 128                   # number of beams
const D = 512                   # number of dishes
#UNDO const F = 16                    # frequency channels per GPU
const F = 1                     # frequency channels per GPU
#UNDO const Wb = 6                    # A matrix tiling
const Wb = 8                    # A matrix tiling
const Wd = 4                    # A matrix tiling
@assert B % Wb == 0
@assert D % Wd == 0
const W = Wb * Wd               # warps per block
const T2 = 32                   # chunk size (inner time cadence)
@assert T % T1 == 0
@assert T1 % T2 == 0
@assert T2 % 4 == 0

const σ = 3 + round(Int, log2(Wd))

################################################################################

# Define physical indices

const Cplx = Index{:Cplx}       # 1 bit (0:re, 1:im)
const Polr = Index{:Polr}       # 1 bit
const Dish = Index{:Dish}       # 9 bits
const Dish′ = Index{:Dish′}     # 9 bits
const Freq = Index{:Freq}       # 8 bits here
const Time = Index{:Time}       # 15 bits
const Beam = Index{:Beam}       # 7 bits (0...95)

const LoopT = Loop1            # outer time loop
const LoopT1 = Loop2
const LoopT2 = Loop3
const LoopB = Loop4
const LoopD = Loop5
const loopIdxT = :loopIdx1
const loopIdxT1 = :loopIdx2
const loopIdxT2 = :loopIdx3
const loopIdxB = :loopIdx4
const loopIdxD = :loopIdx5

const dish2dish′ = Dict(0 => 0, 1 => 1, 2 => 4, 3 => 5, 4 => 6, 5 => 2, 6 => 3, 7 => 7, 8 => 8)
const dish′2dish = Dict(d′ => d for (d, d′) in dish2dish′)
@assert all(dish′2dish[dish2dish′[d]] == d for d in 0:8)
@assert all(dish2dish′[dish′2dish[d′]] == d′ for d′ in 0:8)

################################################################################

# Define memory layouts

# Electric field array E
const map_E_global = let
    m = -1
    Layout(
        Int32,
        Dict(
            Cplx(0) => SIMD(2),
            Dish(0) => SIMD(3),
            Dish(1) => SIMD(4),
            [Dish(d) => Memory(m += 1) for d in 2:(Int(log(2, D)) - 1)]...,
            Polr(0) => Memory(m += 1),
            [Freq(f) => Memory(m += 1) for f in 0:(Int(log(2, F)) - 1)]...,
            [Time(t) => Memory(m += 1) for t in 0:(Int(log(2, T)) - 1)]...,
        ),
    )
end

# Section 3, eqn. (13)
const map_E_shared = let
    m = m2 = -1
    b = -1
    i = -1
    Layout(
        Int32,
        Dict(
            Cplx(0) => SIMD(2),
            Dish(0) => SIMD(3),
            Dish(1) => SIMD(4),
            [Dish(d) => Memory(m += 1) for d in 2:(Int(log(2, D)) - 1)]...,
            Polr(0) => Block(b += 1),
            [Freq(f) => Block(b += 1) for f in 0:(Int(log(2, F)) - 1)]...,
            # TODO: Make padding a compile-time constant, not a run-time choice
            [Time(t) => Memory2(m2 += 1) for t in 0:4]...,
            [Time(t) => Ignore(i += 1) for t in 5:(Int(log(2, T)) - 1)]...,
        ),
    )
end

# Defined in section 3
@assert Wd == 4
@assert Wb == 8
const map_Ecopy_registers = let
    b = -1
    Layout(
        Int32,
        Dict(
            Cplx(0) => SIMD(2),
            Dish(0) => SIMD(3),
            Dish(1) => SIMD(4),
            Dish(2) => Register(0),
            Dish(3) => Register(1),
            Dish(4) => Thread(0),
            Dish(5) => Thread(1),
            Dish(6) => Thread(2),
            Dish(7) => Warp(0),
            Dish(8) => Warp(1),
            Time(0) => Thread(3),
            Time(1) => Thread(4),
            Time(2) => Warp(2),
            Time(3) => Warp(3),
            # TODO: With 24 warps, this will not work
            Time(4) => Warp(4),
            Polr(0) => Block(b += 1),
            [Freq(f) => Block(b += 1) for f in 0:(Int(log(2, F)) - 1)]...,
        ),
    )
end

@assert Wd == 4
@assert D ÷ Wd % 16 == 0
@assert D ÷ Wd ÷ 16 == 8
@assert T2 % 8 == 0
@assert T2 ÷ 8 == 4
const map_E_registers = let
    b = -1
    Layout(
        Int32,
        Dict(
            Cplx(0) => SIMD(2),
            Dish′(0) => SIMD(3),
            Dish′(1) => SIMD(4),
            Dish′(2) => Thread(0),
            Dish′(3) => Thread(1),
            Dish′(4) => LoopD(0),   # since Wd = 4
            Dish′(5) => LoopD(1),   # since Wd = 4
            Dish′(6) => LoopD(2),   # since Wd = 4
            Dish′(7) => Warp(0),    # since Wd = 4
            Dish′(8) => Warp(1),    # since Wd = 4
            Time(0) => Thread(2),
            Time(1) => Thread(3),
            Time(2) => Thread(4),
            Time(3) => LoopT2(0),
            Time(4) => LoopT2(1),
            Polr(0) => Block(b += 1),
            [Freq(f) => Block(b += 1) for f in 0:(Int(log(2, F)) - 1)]...,
        ),
    )
end

# Beamforming matrix A
const map_A_global = let
    m = -1
    i = -1
    Layout(
        Int32,
        Dict(
            # The natural layout
            Cplx(0) => SIMD(3),
            Dish(0) => SIMD(4),
            [Dish(d) => Memory(m += 1) for d in 1:(Int(log(2, D)) - 1)]...,
            [Beam(b) => Memory(m += 1) for b in 0:(Int(log(2, B)) - 1)]...,
            Polr(0) => Memory(m += 1),
            [Freq(f) => Ignore(i += 1) for f in 0:(Int(log(2, F)) - 1)]...,
            # The internal layout
            # Cplx(0) => Memory(0 + 0),
            # Dish′(0) => SIMD(3),
            # Dish′(1) => SIMD(4),
            # Dish′(2) => Memory(5 + 0),
            # Dish′(3) => Memory(5 + 1),
            # Dish′(4) => Memory(0 + 1),
            # Dish′(5) => Memory(0 + 2),
            # Dish′(6) => Memory(0 + 3),
            # Dish′(7) => Memory(10 + 0),
            # Dish′(8) => Memory(10 + 1),
            # Beam(0) => Memory(5 + 2),
            # Beam(1) => Memory(5 + 3),
            # Beam(2) => Memory(5 + 4),
            # Beam(3) => Memory(0 + 4),
            # Beam(4) => Memory(10 + 2),
            # Beam(5) => Memory(10 + 3),
            # Beam(6) => Memory(10 + 4),
        ),
    )
end

# Section 4, eqn (17)
@assert Wd == 4
@assert Wb == 8
const map_A_registers = let
    b = -1
    Layout(
        Int32,
        Dict(
            Cplx(0) => Register(0),
            Dish′(0) => SIMD(3),
            Dish′(1) => SIMD(4),
            Dish′(2) => Thread(0),
            Dish′(3) => Thread(1),
            Dish′(4) => Register(1), # since Wd = 4
            Dish′(5) => Register(2), # since Wd = 4
            Dish′(6) => Register(3), # since Wd = 4
            Dish′(7) => Warp(0),     # since Wd = 4
            Dish′(8) => Warp(1),     # since Wd = 4
            Beam(0) => Thread(2),
            Beam(1) => Thread(3),
            Beam(2) => Thread(4),
            Beam(3) => Register(4), # since Wb = 6
            Beam(4) => Warp(2),     # since Wb = 6
            Beam(5) => Warp(3),     # since Wb = 6
            Beam(6) => Warp(4),     # since Wb = 6
            Polr(0) => Block(b += 1),
            [Freq(f) => Block(b += 1) for f in 0:(Int(log(2, F)) - 1)]...,
        ),
    )
end

# Bit shift parameter
# TODO: How many bits? 4? 8? 32?
const map_s_global = let
    m = -1
    Layout(
        Int32,
        Dict(
            Beam(0) => Memory(m += 1),
            Beam(1) => Memory(m += 1),
            Beam(2) => Memory(m += 1),
            Beam(3) => Memory(m += 1),
            Beam(4) => Memory(m += 1),
            Beam(5) => Memory(m += 1),
            Beam(6) => Memory(m += 1),
            Freq(0) => Memory(m += 1),
            Freq(1) => Memory(m += 1),
            Freq(2) => Memory(m += 1),
            Freq(3) => Memory(m += 1),
            Freq(4) => Memory(m += 1),
            Freq(5) => Memory(m += 1),
            Freq(6) => Memory(m += 1),
            Freq(7) => Memory(m += 1),
            Polr(0) => Memory(m += 1),
        ),
    )
end

# Beamformed electric field
const map_J_global = let
    m = -1
    Layout(
        Int32,
        Dict(
            Cplx(0) => SIMD(2),
            Time(0) => SIMD(3),
            Time(1) => SIMD(4),
            [Time(t) => Memory(m += 1) for t in 2:(Int(log(2, T)) - 1)]...,
            Polr(0) => Memory(m += 1),
            [Freq(f) => Memory(m += 1) for f in 0:(Int(log(2, F)) - 1)]...,
            [Beam(b) => Memory(m += 1) for b in 0:(Int(log(2, B)) - 1)]...,
        ),
    )
end

const map_Ju_shared = let
    m = m2 = m3 = -1
    i = -1
    Layout(
        Int32,
        Dict(
            Cplx(0) => SIMD(4),
            [Beam(b) => Memory(m += 1) for b in 0:(Int(log(2, B)) - 1)]...,
            [Time(t) => Memory2(m2 += 1) for t in 0:Int(log(2, T2) - 1)]...,
            Dish(7) => Memory3(m3 += 1),
            Dish(8) => Memory3(m3 += 1),
            Polr(0) => Ignore(i += 1),
            [Freq(f) => Ignore(i += 1) for f in 0:(Int(log(2, F)) - 1)]...,
        ),
    )
end

################################################################################

function read_A!(steps::Vector{AbstractStep}, env::Environment)
    @assert B == 128
    map_A0_registers = let
        b = -1
        Layout(
            Int32,
            Dict(
                Cplx(0) => SIMD(3),
                Dish(0) => SIMD(4),
                Dish(1) => Register(0),
                Dish(2) => Register(1),
                Dish(3) => Register(2),
                Dish(4) => Register(3),
                Dish(5) => Thread(0),
                Dish(6) => Thread(1),
                Dish(7) => Warp(0),
                Dish(8) => Warp(1),
                Beam(0) => Thread(2),
                Beam(1) => Thread(3),
                Beam(2) => Thread(4),
                Beam(3) => Register(4),
                Beam(4) => Warp(2),
                Beam(5) => Warp(3),
                Beam(6) => Warp(4),
                Polr(0) => Block(b += 1),
                [Freq(f) => Block(b += 1) for f in 0:(Int(log(2, F)) - 1)]...,
            ),
        )
    end
    load!(steps, env, :A0, map_A0_registers, :A_mem, map_A_global)
    rename!(steps, env, :A1, :A0, Dict(Dish(d) => Dish′(dish2dish′[d]) for d in 0:8))
    permute!(steps, env, :A2, :A1, Register(0), SIMD(4))
    permute!(steps, env, :A, :A2, Register(0), SIMD(3))
    @assert env[:A] == map_A_registers
    return nothing
end

# Step 1: transferring global memory to shared memory
function copy_E!(steps::Vector{AbstractStep}, env::Environment)
    load!(steps, env, :Ecopy, map_Ecopy_registers, :E_mem, map_E_global)
    store!(steps, env, :Ecopy, :E_shared, map_E_shared)
    sync_threads!(steps, env)
    return nothing
end

# Step 2: matrix multiplication
function multiply!(steps::Vector{AbstractStep}, env::Environment)
    @assert T2 % 8 == 0
    @assert T2 ÷ 8 == 4
    loop!(steps, env, loopIdxT2, :(Int32(0):Int32($T2 ÷ 8 - 1)), [Time(3), Time(4)]) do steps, env
        @assert D ÷ Wd % 16 == 0
        @assert D ÷ Wd ÷ 16 == 8
        loop!(steps, env, loopIdxD, :(Int32(0):Int32($D ÷ $Wd ÷ 16 - 1)), [Dish(2), Dish(3), Dish(4)]) do steps, env
            map_E0_registers = let
                b = -1
                Layout(
                    Int32,
                    Dict(
                        Cplx(0) => SIMD(2),
                        Dish(0) => SIMD(3),
                        Dish(1) => SIMD(4),
                        Dish(2) => LoopD(0), # since Wd = 4
                        Dish(3) => LoopD(1), # since Wd = 4
                        Dish(4) => LoopD(2), # since Wd = 4
                        Dish(5) => Thread(0),
                        Dish(6) => Thread(1),
                        Dish(7) => Warp(0), # since Wd = 4
                        Dish(8) => Warp(1), # since Wd = 4
                        Time(0) => Thread(2),
                        Time(1) => Thread(3),
                        Time(2) => Thread(4),
                        Time(3) => LoopT2(0),
                        Time(4) => LoopT2(1),
                        Polr(0) => Block(b += 1),
                        [Freq(f) => Block(b += 1) for f in 0:(Int(log(2, F)) - 1)]...,
                    ),
                )
            end
            load!(steps, env, :E0, map_E0_registers, :E_shared, map_E_shared)
            rename!(steps, env, :E1, :E0, Dict(Dish(d) => Dish′(dish2dish′[d]) for d in 0:8))
            @assert env[:E1] == map_E_registers

            # Section 4, eqn (16)
            map_E2_registers = let
                b = -1
                Layout(
                    Int32,
                    Dict(
                        Cplx(0) => Register(0),
                        Dish′(0) => SIMD(3),
                        Dish′(1) => SIMD(4),
                        Dish′(2) => Thread(0),
                        Dish′(3) => Thread(1),
                        Dish′(4) => LoopD(0), # since Wd = 4
                        Dish′(5) => LoopD(1), # since Wd = 4
                        Dish′(6) => LoopD(2), # since Wd = 4
                        Dish′(7) => Warp(0),  # since Wd = 4
                        Dish′(8) => Warp(1),  # since Wd = 4
                        Time(0) => Thread(2),
                        Time(1) => Thread(3),
                        Time(2) => Thread(4),
                        Time(3) => LoopT2(0),
                        Time(4) => LoopT2(1),
                        Polr(0) => Block(b += 1),
                        [Freq(f) => Block(b += 1) for f in 0:(Int(log(2, F)) - 1)]...,
                    ),
                )
            end
            widen!(steps, env, :E2, :E1, SIMD(2) => Register(0))
            @assert env[:E2] == map_E2_registers

            # select!(steps, env, :A3, :A, Register(1), :($loopIdxD & 0b1 ≠ 0))
            # select!(steps, env, :A4, :A3, Register(2), :($loopIdxD & 0b10 ≠ 0))
            # select!(steps, env, :A5, :A4, Register(3), :($loopIdxD & 0b100 ≠ 0))
            select!(steps, env, :A5, :A, [Register(1), Register(2), Register(3)], :($loopIdxD & 0b111))

            @assert B ÷ Wb % 8 == 0
            @assert B ÷ Wb ÷ 8 == 2
            unrolled_loop!(steps, env, loopIdxB, :(Int32(0):Int32($B ÷ $Wb ÷ 8 - 1)), [Beam(6)]) do steps, env
                # select!(steps, env, :A6, :A5, Register(4), :($loopIdxB & 0b1 ≠ 0))
                select!(steps, env, :A6, :A5, [Register(4)], :($loopIdxB & 0b1))
                split!(steps, env, :Are, :Aim, :A6, Cplx(0))

                split!(steps, env, :E2re, :E2im, :E2, Cplx(0))

                map_Ju_registers = let
                    b = -1
                    Layout(
                        Int32,
                        Dict(
                            Dish(7) => Warp(0),
                            Dish(8) => Warp(1),
                            Time(0) => Register(0),
                            Time(1) => Thread(0),
                            Time(2) => Thread(1),
                            Time(3) => LoopT2(0),
                            Time(4) => LoopT2(1),
                            Beam(0) => Thread(2),
                            Beam(1) => Thread(3),
                            Beam(2) => Thread(4),
                            Beam(3) => LoopB(0),    # since Wb = 6
                            Beam(4) => Warp(2),     # since Wb = 6
                            Beam(5) => Warp(3),     # since Wb = 6
                            Beam(6) => Warp(4),     # since Wb = 6
                            Polr(0) => Block(b += 1),
                            [Freq(f) => Block(b += 1) for f in 0:(Int(log(2, F)) - 1)]...,
                        ),
                    )
                end
                constant!(steps, env, :Ju0, map_Ju_registers, :(Int32(0)))
                mma_row_col_m8n8k16_s8!(steps, env, :Jure1, :Aim, :E2im, :Ju0)
                apply!(steps, env, :Jure2, :Jure1, Jure1 -> :(-$Jure1))
                mma_row_col_m8n8k16_s8!(steps, env, :Jure, :Are, :E2re, :Jure2)
                mma_row_col_m8n8k16_s8!(steps, env, :Juim1, :Are, :E2im, :Ju0)
                mma_row_col_m8n8k16_s8!(steps, env, :Juim, :Aim, :E2re, :Juim1)

                # TODO: Break ties to even?
                # TODO: clamp
                #UNDO apply!(steps, env, :Jure3, :Jure, Jure -> :(($Jure + (Int32(1) << $σ) >> 1) >> $σ))
                #UNDO apply!(steps, env, :Juim3, :Juim, Juim -> :(($Juim + (Int32(1) << $σ) >> 1) >> $σ))
                apply!(steps, env, :Jure3, :Jure, Jure -> :($Jure))
                apply!(steps, env, :Juim3, :Juim, Juim -> :($Juim))

                merge!(steps, env, :Ju1, :Jure3, :Juim3, Cplx(0) => Register(1))
                apply!(steps, env, :Ju1′, :Ju1, J -> :(clamp($J, (-Int32(2^15 - 1)):(+Int32(2^15 - 1)))))
                narrow!(steps, env, :Ju2, :Ju1′, Register(1) => SIMD(4))
                @assert env[:Ju2] == let
                    b = -1
                    Layout(
                        Int32,
                        Dict(
                            Cplx(0) => SIMD(4),
                            Time(0) => Register(0),
                            Time(1) => Thread(0),
                            Time(2) => Thread(1),
                            Beam(0) => Thread(2),
                            Beam(1) => Thread(3),
                            Beam(2) => Thread(4),
                            Time(3) => LoopT2(0),
                            Time(4) => LoopT2(1),
                            Beam(3) => LoopB(0),
                            Dish(7) => Warp(0),
                            Dish(8) => Warp(1),
                            Beam(4) => Warp(2),     # since Wb = 6
                            Beam(5) => Warp(3),     # since Wb = 6
                            Beam(6) => Warp(4),     # since Wb = 6
                            Polr(0) => Block(b += 1),
                            [Freq(f) => Block(b += 1) for f in 0:(Int(log(2, F)) - 1)]...,
                        ),
                    )
                end
                store!(steps, env, :Ju2, :Ju_shared, map_Ju_shared)

                nothing
            end
            nothing
        end
        nothing
    end
    sync_threads!(steps, env)

    return nothing
end

# Step 3: reduce and quantize
function reduce!(steps::Vector{AbstractStep}, env::Environment)
    # Section 5, eqn (22)
    map_Ju3_registers = let
        b = -1
        Layout(
            Int32,
            Dict(
                Cplx(0) => SIMD(4),
                Beam(0) => Thread(3),
                Beam(1) => Thread(4),
                Beam(2) => Warp(0),
                Beam(3) => Warp(1),
                Beam(4) => Warp(2),
                Beam(5) => Warp(3),
                Beam(6) => Warp(4),
                Time(0) => Thread(0),
                Time(1) => Thread(1),
                Time(2) => Thread(2),
                Time(3) => Register(3),
                Time(4) => Register(4),
                Dish(7) => Register(0),
                Dish(8) => Register(1),
                Polr(0) => Block(b += 1),
                [Freq(f) => Block(b += 1) for f in 0:(Int(log(2, F)) - 1)]...,
            ),
        )
    end
    load!(steps, env, :Ju3, map_Ju3_registers, :Ju_shared, map_Ju_shared)
    # TODO: Use a saturating add-and-halve instead?
    widen!(steps, env, :Ju4, :Ju3, SIMD(4) => Register(2))
    split!(steps, env, :Ju4a, :Ju4b, :Ju4, Register(0))
    #TODO apply!(steps, env, :Ju5, :Ju4a, :Ju4b, (Ju4a, Ju4b) -> :($Ju4a + $Ju4b))
    apply!(steps, env, :Ju5, :Ju4a, :Ju4b, (Ju4a, Ju4b) -> :(clamp($Ju4a + $Ju4b, (-Int32(2^31 - 1)):(+Int32(2^31 - 1)))))
    split!(steps, env, :Ju5a, :Ju5b, :Ju5, Register(1))
    #TODO apply!(steps, env, :J, :Ju5a, :Ju5b, (Ju5a, Ju5b) -> :($Ju5a + $Ju5b))
    apply!(steps, env, :J, :Ju5a, :Ju5b, (Ju5a, Ju5b) -> :(clamp($Ju5a + $Ju5b, (-Int32(2^31 - 1)):(+Int32(2^31 - 1)))))
    # Section 5, eqn. (24)
    map_J_registers = let
        b = -1
        Layout(
            Int32,
            Dict(
                Cplx(0) => Register(2),
                Time(0) => Thread(0),
                Time(1) => Thread(1),
                Time(2) => Thread(2),
                Time(3) => Register(3),
                Time(4) => Register(4),
                Beam(0) => Thread(3),
                Beam(1) => Thread(4),
                Beam(2) => Warp(0),
                Beam(3) => Warp(1),
                Beam(4) => Warp(2),
                Beam(5) => Warp(3),
                Beam(6) => Warp(4),
                Polr(0) => Block(b += 1),
                [Freq(f) => Block(b += 1) for f in 0:(Int(log(2, F)) - 1)]...,
            ),
        )
    end
    @assert env[:J] == map_J_registers

    # TODO: Use s_β
    # TODO: clamp
    #UNDO apply!(steps, env, :J2, :J, J -> :(($J + (Int32(1) << (16 - 1 - $σ))) >> (16 - $σ)))
    apply!(steps, env, :J2, :J, J -> :($J))

    apply!(steps, env, :J2′, :J2, J -> :(clamp($J, (-Int32(2^3 - 1)):(+Int32(2^3 - 1)))))
    narrow3!(steps, env, :J3, :J2′, Register(2) => SIMD(2), Register(3) => SIMD(3), Register(4) => SIMD(4))
    # Section 5, eqn. (26)
    map_J3_registers = let
        b = -1
        Layout(
            Int32,
            Dict(
                Cplx(0) => SIMD(2),
                Time(0) => Thread(0),
                Time(1) => Thread(1),
                Time(2) => Thread(2),
                Time(3) => SIMD(3),
                Time(4) => SIMD(4),
                Beam(0) => Thread(3),
                Beam(1) => Thread(4),
                Beam(2) => Warp(0),
                Beam(3) => Warp(1),
                Beam(4) => Warp(2),
                Beam(5) => Warp(3),
                Beam(6) => Warp(4),
                Polr(0) => Block(b += 1),
                [Freq(f) => Block(b += 1) for f in 0:(Int(log(2, F)) - 1)]...,
            ),
        )
    end
    @assert env[:J3] == map_J3_registers

    unselect!(steps, env, :Jper, :J3, [Time(5) => Register(0), Time(6) => Register(1)], :($loopIdxT1 & 0b11))
    # Section 5, eqn. (27), but Time(5:6) replaced by Time(3:4)
    map_Jper_registers = let
        b = -1
        Layout(
            Int32,
            Dict(
                Cplx(0) => SIMD(2),
                # Time(5) => SIMD(3),
                # Time(6) => SIMD(4),
                # Time(3) => Register(3),
                # Time(4) => Register(4),
                Time(0) => Thread(0),
                Time(1) => Thread(1),
                Time(2) => Thread(2),
                Time(3) => SIMD(3),
                Time(4) => SIMD(4),
                Time(5) => Register(0),
                Time(6) => Register(1),
                Beam(0) => Thread(3),
                Beam(1) => Thread(4),
                Beam(2) => Warp(0),
                Beam(3) => Warp(1),
                Beam(4) => Warp(2),
                Beam(5) => Warp(3),
                Beam(6) => Warp(4),
                Polr(0) => Block(b += 1),
                [Freq(f) => Block(b += 1) for f in 0:(Int(log(2, F)) - 1)]...,
            ),
        )
    end
    @assert env[:Jper] == map_Jper_registers

    return nothing
end

function write_J!(steps::Vector{AbstractStep}, env::Environment)
    map_Jper_registers = let
        b = -1
        Layout(
            Int32,
            Dict(
                Cplx(0) => SIMD(2),
                # Time(5) => SIMD(3),
                # Time(6) => SIMD(4),
                # Time(3) => Register(3),
                # Time(4) => Register(4),
                Time(0) => Thread(0),
                Time(1) => Thread(1),
                Time(2) => Thread(2),
                Time(3) => SIMD(3),
                Time(4) => SIMD(4),
                Time(5) => Register(0),
                Time(6) => Register(1),
                Beam(0) => Thread(3),
                Beam(1) => Thread(4),
                Beam(2) => Warp(0),
                Beam(3) => Warp(1),
                Beam(4) => Warp(2),
                Beam(5) => Warp(3),
                Beam(6) => Warp(4),
                Polr(0) => Block(b += 1),
                [Freq(f) => Block(b += 1) for f in 0:(Int(log(2, F)) - 1)]...,
            ),
        )
    end
    @assert env[:Jper] == map_Jper_registers

    permute!(steps, env, :Jper2, :Jper, Register(0), SIMD(3))
    permute!(steps, env, :Jper3, :Jper2, Register(0), Thread(0))
    permute!(steps, env, :Jper4, :Jper3, Register(0), SIMD(3))
    permute!(steps, env, :Jper5, :Jper4, Register(1), Thread(1))
    permute!(steps, env, :Jper6, :Jper5, Register(1), SIMD(4))
    permute!(steps, env, :Jper7, :Jper6, Register(0), Thread(2))
    permute!(steps, env, :Jstore, :Jper7, Register(1), Thread(0))

    map_Jstore_registers = let
        b = -1
        Layout(
            Int32,
            Dict(
                Cplx(0) => SIMD(2),
                Time(0) => SIMD(3),
                Time(1) => SIMD(4),
                Time(2) => Register(0),
                Time(3) => Register(1),
                Time(4) => Thread(0),
                Time(5) => Thread(2),
                Time(6) => Thread(1),
                Beam(0) => Thread(3),
                Beam(1) => Thread(4),
                Beam(2) => Warp(0),
                Beam(3) => Warp(1),
                Beam(4) => Warp(2),
                Beam(5) => Warp(3),
                Beam(6) => Warp(4),
                Polr(0) => Block(b += 1),
                [Freq(f) => Block(b += 1) for f in 0:(Int(log(2, F)) - 1)]...,
            ),
        )
    end
    @assert env[:Jstore] == map_Jstore_registers

    # TODO: Use 16-byte stores
    store!(steps, env, :Jstore, :J_mem, map_J_global)

    return nothing
end

function bb!(steps::Vector{AbstractStep}, env::Environment)
    read_A!(steps, env)
    @assert T % T1 == 0
    loop!(steps, env, loopIdxT, :(Int32(0):Int32($T ÷ $T1 - 1)), [Time(t) for t in 7:14]) do steps, env
        @assert T1 % T2 == 0
        @assert T1 ÷ T2 == 4
        loop!(steps, env, loopIdxT1, :(Int32(0):Int32($T1 ÷ $T2 - 1)), [Time(5), Time(6)]) do steps, env
            copy_E!(steps, env)
            multiply!(steps, env)
            reduce!(steps, env)
            return nothing
        end
        write_J!(steps, env)
        return nothing
    end
    return nothing
end

bb_steps = AbstractStep[]
bb_env = Environment()
bb!(bb_steps, bb_env)
bb_allsteps = Seq(bb_steps)

@assert D % 4 == 0
const E_shared_size = (D ÷ 4 + 1, T2)
const Ju_shared_size = (B + 4, T2, Wd)

const E_shared_length = prod(E_shared_size)
const Ju_shared_length = prod(Ju_shared_size)

const E_shared_offset = 0
const Ju_shared_offset = E_shared_length

const shmem_length = E_shared_length + Ju_shared_length
const shmem_bytes = sizeof(Int32) * shmem_length

@eval function runsteps(A_mem, E_mem, J_mem, E_shared, Ju_shared)
    E_shared = @cuDynamicSharedMem(Int4x8, $E_shared_size, $(sizeof(Int32) * E_shared_offset))
    Ju_shared = @cuDynamicSharedMem(Int16x2, $Ju_shared_size, $(sizeof(Int32) * Ju_shared_offset))
    $(declarations(bb_allsteps))
    $(code(bb_allsteps))
    return nothing
end

function runcuda()
    println("Baseband beamformer v2")
    println("J[b,f,p,t] = Σ[d] A[p,b,d] E[d,p,f,t]")
    println("Setting up inputs...")

    # Cplx, Dish, Beam, Polr
    A_input = zeros(Int8, 2, nextpow(2, D), nextpow(2, B), 2)

    # Dish, Polr, Freq, Time
    E_input = zeros(Int4x2, nextpow(2, D), 2, nextpow(2, F), nextpow(2, T))

    # Time, Polr, Freq, Beam
    J_input = zeros(Int4x2, nextpow(2, T), 2, nextpow(2, F), nextpow(2, B))

    ibeam = 1
    idish = 1
    ifreq = 1
    ipolr = 1
    itime = 1

    A_input[1, idish, ibeam, ipolr] = 1
    # for d in 1:D
    #     A_input[1, d, ibeam, ipolr] = 1
    # end
    # for d in 1:D
    #     A_input[2, d, ibeam, ipolr] = 1
    # end
    # vvvvv
    # ^^^^^
    for d in 1:D
        A_input[1, d, ibeam, ipolr] = 1
    end
    # for d in 1:D, c in 1:2
    #     A_input[c, d, ibeam, ipolr] = 1
    # end
    # for b in 1:B, d in 1:D, c in 1:2
    #     A_input[c, d, b, ipolr] = 1
    # end
    # for p in 1:2, b in 1:B, d in 1:D, c in 1:2
    #     A_input[c, d, b, p] = 1
    # end
    # A_input .= 1

    # E_input[idish, ipolr, ifreq, itime] = Int4x2(Int32(1), Int32(1))
    # for d in 1:D
    #     E_input[d, ipolr, ifreq, itime] = Int4x2(Int32(1), Int32(0))
    # end
    # for d in 1:D
    #     E_input[d, ipolr, ifreq, itime] = Int4x2(Int32(0), Int32(1))
    # end
    # vvvvv
    # ^^^^^
    for d in 1:D
        E_input[d, ipolr, ifreq, itime] = Int4x2(Int32(1), Int32(0))
    end
    # for p in 1:2, d in 1:D
    #     E_input[d, p, ifreq, itime] = Int4x2(Int32(1), Int32(1))
    # end
    # for f in 1:F, p in 1:2, d in 1:D
    #     E_input[d, p, f, itime] = Int4x2(Int32(1), Int32(1))
    # end
    # for t in 1:T, f in 1:F, p in 1:2, d in 1:D
    #     E_input[d, p, f, t] = Int4x2(Int32(1), Int32(1))
    # end
    # for i in eachindex(E_input)
    #     E_input[i] = Int4x2(Int32(1), Int32(1))
    # end

    A_mem = reinterpret(Int8x4, reshape(A_input, :))
    E_mem = reinterpret(Int4x8, reshape(E_input, :))
    J_mem = reinterpret(Int4x8, reshape(J_input, :))

    E_shared = zeros(Int4x8, E_shared_size)
    Ju_shared = zeros(Int16x2, Ju_shared_size)

    println("Copying inputs to device...")
    A_mem = CuArray(A_mem)
    E_mem = CuArray(E_mem)
    J_mem = CuArray(J_mem)
    E_shared = CuArray(E_shared)
    Ju_shared = CuArray(Ju_shared)

    println("Compiling kernel...")
    nthreads = 32
    nwarps = Wb * Wd
    nblocks = 2 * F                 # Polr, Freq
    @assert shmem_bytes ≤ 99 * 1024 # NVIDIA A10 has 99 kB shared memory

    blocks_per_sm = 1
    # maxregs = 65536 ÷ (nthreads * nwarps * blocks_per_sm)
    kernel = @cuda launch = false minthreads = nthreads * nwarps blocks_per_sm = blocks_per_sm runsteps(
        A_mem, E_mem, J_mem, E_shared, Ju_shared
    )

    println("Running kernel...")
    attributes(kernel.fun)[CUDA.CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES] = shmem_bytes
    kernel(A_mem, E_mem, J_mem, E_shared, Ju_shared; threads=(nthreads, nwarps), blocks=nblocks, shmem=shmem_bytes)
    synchronize()

    println("Copying outputs from device...")
    E_shared = Array(E_shared)
    Ju_shared = Array(Ju_shared)

    J_mem = Array(J_mem)

    println("Checking outputs...")
    J_output = reshape(reinterpret(Int4x2, J_mem), nextpow(2, T), 2, nextpow(2, F), nextpow(2, B))
    let
        nzcount = 0
        for b in 1:B, f in 1:F, p in 1:2, t in 1:T
            if J_output[t, p, f, b] ≠ zero(Int4x2)
                println("J[$t,$p,$f,$b] = $(convert(NTuple{2,Int8}, J_output[t,p,f,b]))")
                nzcount += 1
            end
            nzcount == 100 && break
        end
        @assert nzcount == 0
    end

    println("Done.")
    return nothing
end

println(bb_allsteps)
if CUDA.functional()
    # @device_code_lowered runcuda()
    # @device_code_typed runcuda()
    # @device_code_warntype runcuda()
    # @device_code_llvm runcuda()
    # @device_code_ptx runcuda()
    # @device_code_sass runcuda()
    # @device_code runcuda()
    runcuda()
end