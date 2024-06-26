# Reader Helper
# =============
#
# Utilities to generate file readers in BioJulia packages.
#
# This file is a part of BioJulia.
# License is MIT: https://github.com/BioJulia/BioCore.jl/blob/master/LICENSE.md

module ReaderHelper

import Automa
import BufferedStreams

mutable struct State{T<:BufferedStreams.BufferedInputStream}
    stream::T      # input stream
    cs::Int        # current DFA state of Ragel
    linenum::Int   # line number: parser is responsible for updating this
    finished::Bool # true if finished (regardless of where in the stream we are)
end

function State(initstate::Int, input::BufferedStreams.BufferedInputStream)
    return State(input, initstate, 1, false)
end



@inline function anchor!(stream::BufferedStreams.BufferedInputStream, p, immobilize = true)
    stream.anchor = p
    stream.immobilized = immobilize
    return stream
end

@inline function upanchor!(stream::BufferedStreams.BufferedInputStream)
    @assert stream.anchor != 0 "upanchor! called with no anchor set"
    anchor = stream.anchor
    stream.anchor = 0
    stream.immobilized = false
    return anchor
end

function ensure_margin!(stream::BufferedStreams.BufferedInputStream)
    if stream.position * 20 > length(stream.buffer) * 19
        BufferedStreams.shiftdata!(stream)
    end
    return nothing
end

@inline function resize_and_copy!(dst::Vector{UInt8}, src::Vector{UInt8}, r::UnitRange{Int})
    return resize_and_copy!(dst, 1, src, r)
end

@inline function resize_and_copy!(dst::Vector{UInt8}, dstart::Int, src::Vector{UInt8}, r::UnitRange{Int})
    rlen = length(r)
    if length(dst) != dstart + rlen - 1
        resize!(dst, dstart + rlen - 1)
    end
    copyto!(dst, dstart, src, first(r), rlen)
    return dst
end

@inline function append_from_anchor!(dst::Vector{UInt8}, dstart::Int, stream::BufferedStreams.BufferedInputStream, p::Int)
    return resize_and_copy!(dst, dstart, stream.buffer, upanchor!(stream):p)
end

function generate_index_function(record_type, machine, init_code, actions; kwargs...)
    kwargs = Dict(kwargs)
    context = Automa.CodeGenContext(
        generator = get(kwargs, :generator, :goto),
        checkbounds = get(kwargs, :checkbounds, false),
        loopunroll = get(kwargs, :loopunroll, 0)
    )
    quote
        function index!(record::$(record_type))
            data = record.data
            p = 1
            p_end = p_eof = sizeof(data)
            initialize!(record)
            $(init_code)
            cs = $(machine.start_state)
            $(Automa.generate_exec_code(context, machine, actions))
            if cs != 0
                throw(ArgumentError(string("failed to index ", $(record_type), " ~>", repr(String(data[p:min(p+7,p_end)])))))
            end
            @assert isfilled(record)
            return record
        end
    end
end

function generate_readheader_function(reader_type, metainfo_type, machine, init_code, actions, finish_code=:())
    quote
        function readheader!(reader::$(reader_type))
            _readheader!(reader, reader.state)
        end

        function _readheader!(reader::$(reader_type), state::ReaderHelper.State)
            stream = state.stream
            ReaderHelper.ensure_margin!(stream)
            cs = state.cs
            linenum = state.linenum
            data = stream.buffer
            p = stream.position
            p_end = stream.available
            p_eof = -1
            finish_header = false
            record = $(metainfo_type)()

            $(init_code)

            while true
                $(Automa.generate_exec_code(Automa.CodeGenContext(generator=:table), machine, actions))

                state.cs = cs
                state.finished = cs == 0
                state.linenum = linenum
                stream.position = p

                if cs < 0
                    error("$($(reader_type)) file format error on line ", linenum)
                elseif finish_header
                    $(finish_code)
                    break
                elseif p > p_eof ≥ 0
                    error("incomplete $($(reader_type)) input on line ", linenum)
                else
                    hits_eof = BufferedStreams.fillbuffer!(stream) == 0
                    p = stream.position
                    p_end = stream.available
                    if hits_eof
                        p_eof = p_end
                    end
                end
            end
        end
    end
end

function generate_read_function(reader_type, machine, init_code, actions; kwargs...)
    kwargs = Dict(kwargs)
    context = Automa.CodeGenContext(
        generator=get(kwargs, :generator, :goto),
        checkbounds=get(kwargs, :checkbounds, false),
        loopunroll=get(kwargs, :loopunroll, 0)
    )
    quote
        function Base.read!(reader::$(reader_type), record::eltype($(reader_type)))::eltype($(reader_type))
            return _read!(reader, reader.state, record)
        end

        function _read!(reader::$(reader_type), state::ReaderHelper.State, record::eltype($(reader_type)))
            stream = state.stream
            ReaderHelper.ensure_margin!(stream)
            cs = state.cs
            linenum = state.linenum
            data = stream.buffer
            p = stream.position
            p_end = stream.available
            p_eof = -1
            found_record = false
            initialize!(record)

            $(init_code)

            if state.finished
                throw(EOFError())
            end

            while true
                $(Automa.generate_exec_code(context, machine, actions))

                state.cs = cs
                state.finished |= cs == 0
                state.linenum = linenum
                stream.position = p

                if cs < 0
                    error($(reader_type), " file format error on line ", linenum, " ~>", repr(String(data[p:min(p+7,p_end)])))
                elseif found_record
                    break
                elseif cs == 0
                    throw(EOFError())
                elseif p > p_eof ≥ 0
                    error("incomplete $($(reader_type)) input on line ", linenum)
                elseif BufferedStreams.available_bytes(stream) < 64
                    hits_eof = BufferedStreams.fillbuffer!(stream) == 0
                    p = stream.position
                    p_end = stream.available
                    if hits_eof
                        p_eof = p_end
                    end
                end
            end

            @assert isfilled(record)
            return record
        end
    end
end

end
