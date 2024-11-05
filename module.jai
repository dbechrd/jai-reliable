/*
Native Jai port of Glenn Fiedler's "reliable" C library as of this commit:
https://github.com/mas-bandwidth/reliable/commit/49b09d0726a09e16857315ec400df5dc185e07ee

------------------------------------------------------------------------------------------------------------------------
| Original BSD-3 license
------------------------------------------------------------------------------------------------------------------------
    reliable

    Copyright © 2017 - 2024, Mas Bandwidth LLC

    Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

        1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

        2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer
           in the documentation and/or other materials provided with the distribution.

        3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived
           from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
    INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
    SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
    SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
    WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
    USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

-----------------------------------------------------------------------------------------------------------------------
| Documentation (Quick Reference)
-----------------------------------------------------------------------------------------------------------------------

// Provide these via config when calling `reliable_endpoint_create` to receive
// callbacks when Reliable is ready to send/receive network traffic.

    TransmitPacketFunction (ctx: *void, id: u64, sequence: u16, packet_data: [] u8);
    ProcessPacketFunction (ctx: *void, id: u64, sequence: u16, packet_data: [] u8) -> int;

// Create a new endpoint (e.g. client or server)

    reliable_endpoint_create (config: *reliable_config_t, time: Apollo_Time) -> *reliable_endpoint_t

// Destroy an existing endpoint

    reliable_endpoint_destroy (endpoint: *reliable_endpoint_t)

// Send a packet with acks (calls user-supplied `TransmitPacketFunction`)

    reliable_endpoint_send_packet (endpoint: *reliable_endpoint_t, packet_data: [] u8)

// Receive a packet with acks (calls user-supplied `ProcessPacketFunction`)

    reliable_endpoint_receive_packet (endpoint: *reliable_endpoint_t, packet_data: [] u8)

// Get a list of sequence numbers that have been ack'd recently

    reliable_endpoint_get_acks (endpoint: *reliable_endpoint_t) -> [] u16

// Mark all of the acks as handled (i.e. clear the ack buffer for re-use)

    reliable_endpoint_clear_acks (endpoint: *reliable_endpoint_t)

// Reset the endpoint to its initial state (retaining the config and sequence buffer allocs)

    reliable_endpoint_reset (endpoint: *reliable_endpoint_t)

// Update time and statistics

    reliable_endpoint_update (endpoint: *reliable_endpoint_t, time: Apollo_Time)

// Query current stats (with smoothing, see config)

    reliable_endpoint_rtt (endpoint: *reliable_endpoint_t) -> float
    reliable_endpoint_packet_loss (endpoint: *reliable_endpoint_t ) -> float
    reliable_endpoint_bandwidth (endpoint: *reliable_endpoint_t) -> sent_bandwidth_kbps: float, received_bandwidth_kbps: float, acked_bandwidth_kpbs: float

// Query current performance counters

    reliable_endpoint_counters (endpoint: *reliable_endpoint_t) -> [RELIABLE_ENDPOINT_NUM_COUNTERS] u64

-----------------------------------------------------------------------------------------------------------------------
*/

#module_parameters () (ENABLE_LOGGING := false);

#load "tests.jai";

// TODO(dlb): This is kind of stupid.. just make it a struct
RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_SENT                 :: 0;
RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_RECEIVED             :: 1;
RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_ACKED                :: 2;
RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_STALE                :: 3;
RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_INVALID              :: 4;
RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_TOO_LARGE_TO_SEND    :: 5;
RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_TOO_LARGE_TO_RECEIVE :: 6;
RELIABLE_ENDPOINT_COUNTER_NUM_FRAGMENTS_SENT               :: 7;
RELIABLE_ENDPOINT_COUNTER_NUM_FRAGMENTS_RECEIVED           :: 8;
RELIABLE_ENDPOINT_COUNTER_NUM_FRAGMENTS_INVALID            :: 9;
RELIABLE_ENDPOINT_NUM_COUNTERS                             :: 10;

RELIABLE_MAX_PACKET_HEADER_BYTES :: 9;
RELIABLE_FRAGMENT_HEADER_BYTES   :: 5;

// TODO(dlb): Enum
RELIABLE_OK    :: 1;
RELIABLE_ERROR :: 0;

TransmitPacketFunction :: #type (ctx: *void, id: u64, sequence: u16, packet_data: [] u8);
ProcessPacketFunction :: #type (ctx: *void, id: u64, sequence: u16, packet_data: [] u8) -> bool;

reliable_config_t :: struct {
    name                            : string = "Endpoint";    // TODO(dlb): Assert that this has count < 256
    ctx                             : *void;                  // Arbitrary user data to be supplied to Transmit/Process callbacks
    id                              : u64;                    // Arbitrary id to be supplised to Transmit/Process callbacks
    max_packet_size                 : int = 16 * 1024;        // Maximum packet size, in bytes
    fragment_above                  : int = 1024;             // Size in bytes beyond which packets should be fragmented
    max_fragments                   : int = 16;               // Maximum number of fragments to split a single packet into
    fragment_size                   : int = 1024;             // Size of each fragment (except the last one, which is partial)
    ack_buffer_size                 : int = 256;              // Maximum acks to store between each call to clear_acks()
    sent_packets_buffer_size        : int = 256;              // Maximum sent packet stats to keep
    received_packets_buffer_size    : int = 256;              // Maximum received packets stats to keep
    fragment_reassembly_buffer_size : int = 64;               // Maximum fragments to be kept for reassembly at any given time
    rtt_smoothing_factor            : float = 0.0025;         // Stats smoothing factor
    packet_loss_smoothing_factor    : float = 0.1;            // Stats smoothing factor
    bandwidth_smoothing_factor      : float = 0.1;            // Stats smoothing factor
    // TODO(dlb): Make IPv6 a module parameter so that we can increase this to 48 in that case?
    packet_header_size              : int = 28;               // UDP over IPv4 = 20 + 8 bytes, UDP over IPv6 = 40 + 8 bytes
    transmit_packet_function        : TransmitPacketFunction; // User-supplied callback for transmitting packets
    process_packet_function         : ProcessPacketFunction;  // User-supplied callback for processing packets
};

reliable_endpoint_t :: struct {
    config                  : reliable_config_t;
    time                    : Apollo_Time;
    rtt                     : float;
    packet_loss             : float;
    sent_bandwidth_kbps     : float;
    received_bandwidth_kbps : float;
    acked_bandwidth_kbps    : float;
    num_acks                : int;
    acks                    : [] u16;
    sequence                : u16;
    sent_packets            : *reliable_sequence_buffer_t;
    received_packets        : *reliable_sequence_buffer_t;
    fragment_reassembly     : *reliable_sequence_buffer_t;
    counters                : [RELIABLE_ENDPOINT_NUM_COUNTERS] u64;
};

// NOTE(dlb): These are.. pointless. Don't waste the user's time.
// reliable_init :: inline () -> int {
//     return RELIABLE_OK;
// }

// reliable_term :: inline () {
// }

reliable_endpoint_create :: (config: *reliable_config_t, time: Apollo_Time) -> *reliable_endpoint_t {
    assert(config != null);
    // NOTE(dlb): This is probably more than we need, but the C impl used char[256] so we'll just set that as max for now.
    assert(config.name.count < 256);
    assert(config.max_packet_size > 0);
    assert(config.fragment_above > 0);
    assert(config.fragment_size > 0);
    assert(config.ack_buffer_size > 0);
    assert(config.sent_packets_buffer_size > 0);
    assert(config.received_packets_buffer_size > 0);
    assert(config.transmit_packet_function != null);
    assert(config.process_packet_function != null);

    // We don't care what the user wants here. This field has to be calculated to guarantee correctness.
    config.max_fragments = cast(int) ceil(cast(float) config.max_packet_size / config.fragment_above);

    // TODO(dlb): We could combine the allocs and update `reliable_endpoint_destroy` to do a single free()
    endpoint := New(reliable_endpoint_t);
    assert(endpoint != null);
    endpoint.config = config.*;
    endpoint.time = time;
    endpoint.acks = NewArray(config.ack_buffer_size, u16);
    endpoint.sent_packets = reliable_sequence_buffer_create(config.sent_packets_buffer_size, size_of(reliable_sent_packet_data_t));
    endpoint.received_packets = reliable_sequence_buffer_create(config.received_packets_buffer_size, size_of(reliable_received_packet_data_t));
    endpoint.fragment_reassembly = reliable_sequence_buffer_create(config.fragment_reassembly_buffer_size, size_of(reliable_fragment_reassembly_data_t));
    return endpoint;
}

reliable_endpoint_destroy :: (endpoint: *reliable_endpoint_t) {
    assert(endpoint != null);
    assert(endpoint.acks.count > 0);
    assert(endpoint.sent_packets != null);
    assert(endpoint.received_packets != null);

    for 0..endpoint.config.fragment_reassembly_buffer_size-1 {
        reassembly_data := reliable_sequence_buffer_at_index(endpoint.fragment_reassembly, it);
        if reassembly_data != null && reassembly_data.packet_data.data != null {
            array_free(reassembly_data.packet_data);
        }
    }

    array_free(endpoint.acks);
    reliable_sequence_buffer_destroy(endpoint.sent_packets);
    reliable_sequence_buffer_destroy(endpoint.received_packets);
    reliable_sequence_buffer_destroy(endpoint.fragment_reassembly);
    free(endpoint);
}

reliable_endpoint_next_packet_sequence :: inline (endpoint: *reliable_endpoint_t) -> u16 {
    assert(endpoint != null);

    return endpoint.sequence;
}

reliable_endpoint_send_packet :: (endpoint: *reliable_endpoint_t, packet_data: [] u8) {
    assert(endpoint != null);
    assert(packet_data.count > 0);

    if packet_data.count > endpoint.config.max_packet_size {
        reliable_log(.ERROR, "[%] packet too large to send. packet is % bytes, maximum is %\n", endpoint.config.name, packet_data.count, endpoint.config.max_packet_size);
        endpoint.counters[RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_TOO_LARGE_TO_SEND] += 1;
        return;
    }

    sequence: u16 = endpoint.sequence;
    endpoint.sequence += 1;
    ack, ack_bits := reliable_sequence_buffer_generate_ack_bits(endpoint.received_packets);

    reliable_log(.VERY_VERBOSE_ONLY, "[%] sending packet %\n", endpoint.config.name, sequence);

    sent_packet_data := cast(*reliable_sent_packet_data_t) reliable_sequence_buffer_insert(endpoint.sent_packets, sequence);
    assert(sent_packet_data != null);

    sent_packet_data.time = endpoint.time;
    sent_packet_data.packet_bytes = endpoint.config.packet_header_size + packet_data.count;
    sent_packet_data.acked = false;

    // --- vvv --------- Temp Allocator --------- vvv ---
    push_allocator(temp);

    if packet_data.count <= endpoint.config.fragment_above {
        // regular packet
        reliable_log(.VERY_VERBOSE_ONLY, "[%] sending packet % without fragmentation\n", endpoint.config.name, sequence);

        transmit_packet_data: [] u8 = NewArray(RELIABLE_MAX_PACKET_HEADER_BYTES + packet_data.count, u8, initialized = false);

        packet_header_bytes := reliable_write_packet_header(transmit_packet_data, sequence, ack, ack_bits);
        memcpy(transmit_packet_data.data + packet_header_bytes, packet_data.data, packet_data.count);

        transmit_packet_data.count = packet_header_bytes + packet_data.count;
        assert(endpoint.config.transmit_packet_function != null);
        endpoint.config.transmit_packet_function(endpoint.config.ctx, endpoint.config.id, sequence, transmit_packet_data);
    } else {
        // fragmented packet
        packet_header: [RELIABLE_MAX_PACKET_HEADER_BYTES] u8 = ---;

        packet_header_bytes := reliable_write_packet_header(packet_header, sequence, ack, ack_bits);
        num_fragments: int = (packet_data.count / endpoint.config.fragment_size) + (ifx packet_data.count % endpoint.config.fragment_size != 0 then 1 else 0);

        reliable_log(.VERY_VERBOSE_ONLY, "[%] sending packet % as % fragments\n", endpoint.config.name, sequence, num_fragments);

        assert(num_fragments >= 1);
        assert(num_fragments <= endpoint.config.max_fragments);

        // NOTE(dlb): This buffer gets re-used for each fragment. I found that a bit confusing when I first read the code.
        fragment_buffer_size: int = RELIABLE_FRAGMENT_HEADER_BYTES + RELIABLE_MAX_PACKET_HEADER_BYTES + endpoint.config.fragment_size;
        fragment_packet_data: [] u8 = NewArray(fragment_buffer_size, u8, initialized = false);

        src: *u8 = packet_data.data;
        end: *u8 = src + packet_data.count;

        for fragment_id: 0..num_fragments-1 {
            dst: *u8 = fragment_packet_data.data;  // Reset to start of temp buffer

            reliable_write_uint8(*dst, 1);
            reliable_write_uint16(*dst, sequence);
            reliable_write_uint8(*dst, cast(u8) fragment_id);
            reliable_write_uint8(*dst, cast(u8) (num_fragments - 1));

            // Prepend header into first fragment
            if fragment_id == 0 {
                memcpy(dst, packet_header.data, packet_header_bytes);
                dst += packet_header_bytes;
            }

            bytes_to_copy := endpoint.config.fragment_size;
            if src + bytes_to_copy > end {
                bytes_to_copy = end - src;
            }

            memcpy(dst, src, bytes_to_copy);
            dst += bytes_to_copy;
            src += bytes_to_copy;

            fragment_packet_data.count = pointer_diff(dst, fragment_packet_data.data);
            assert(endpoint.config.transmit_packet_function != null);
            endpoint.config.transmit_packet_function(endpoint.config.ctx, endpoint.config.id, sequence, fragment_packet_data);

            endpoint.counters[RELIABLE_ENDPOINT_COUNTER_NUM_FRAGMENTS_SENT] += 1;
        }
    }

    endpoint.counters[RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_SENT] += 1;
}

reliable_endpoint_receive_packet :: (endpoint: *reliable_endpoint_t, packet_data: [] u8) {
    assert(endpoint != null);
    assert(packet_data.count > 0);

    if packet_data.count > endpoint.config.max_packet_size + RELIABLE_MAX_PACKET_HEADER_BYTES + RELIABLE_FRAGMENT_HEADER_BYTES {
        reliable_log(.VERY_VERBOSE_ONLY,
            "[%] packet too large to receive. packet is at least % bytes, maximum is %\n",
            endpoint.config.name,
            packet_data.count - (RELIABLE_MAX_PACKET_HEADER_BYTES + RELIABLE_FRAGMENT_HEADER_BYTES),
            endpoint.config.max_packet_size
        );
        endpoint.counters[RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_TOO_LARGE_TO_RECEIVE] += 1;
        return;
    }

    prefix_byte := packet_data[0];

    if (prefix_byte & 1) == 0 {
        // regular packet
        endpoint.counters[RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_RECEIVED] += 1;

        packet_header_bytes, sequence, ack, ack_bits := reliable_read_packet_header(endpoint.config.name, packet_data);
        if packet_header_bytes < 0 {
            reliable_log(.VERY_VERBOSE_ONLY, "[%] ignoring invalid packet. could not read packet header\n", endpoint.config.name);
            endpoint.counters[RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_INVALID] += 1;
            return;
        }

        assert(packet_header_bytes <= packet_data.count);

        packet_payload_bytes: int = packet_data.count - packet_header_bytes;

        if packet_payload_bytes > endpoint.config.max_packet_size {
            reliable_log(.ERROR,
                "[%] packet too large to receive. packet is at % bytes, maximum is %\n",
                endpoint.config.name, packet_payload_bytes, endpoint.config.max_packet_size);
            endpoint.counters[RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_TOO_LARGE_TO_RECEIVE] += 1;
            return;
        }

        if !reliable_sequence_buffer_test_insert(endpoint.received_packets, sequence) {
            reliable_log(.VERY_VERBOSE_ONLY, "[%] ignoring stale packet %\n", endpoint.config.name, sequence);
            endpoint.counters[RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_STALE] += 1;
            return;
        }

        reliable_log(.VERY_VERBOSE_ONLY, "[%] processing packet %\n", endpoint.config.name, sequence);

        packet_body := packet_data;
        packet_body.data += packet_header_bytes;
        packet_body.count -= packet_header_bytes;

        assert(endpoint.config.process_packet_function != null);
        if endpoint.config.process_packet_function(endpoint.config.ctx, endpoint.config.id, sequence, packet_body) {
            reliable_log(.VERY_VERBOSE_ONLY, "[%] process packet % successful\n", endpoint.config.name, sequence);

            received_packet_data := cast(*reliable_received_packet_data_t) reliable_sequence_buffer_insert(endpoint.received_packets, sequence);
            assert(received_packet_data != null);

            reliable_sequence_buffer_advance(endpoint.fragment_reassembly, sequence, cleanup = true);

            received_packet_data.time = endpoint.time;
            received_packet_data.packet_bytes = endpoint.config.packet_header_size + packet_data.count;

            for 0..31 {
                if ack_bits & 1 {
                    ack_sequence: u16 = ack - cast(u16) it;

                    sent_packet_data := cast(*reliable_sent_packet_data_t) reliable_sequence_buffer_find(endpoint.sent_packets, ack_sequence);

                    // TODO(dlb): What happens when endpoint.acks fills up?? Presumably whoever is using Reliable is responsible for
                    // reading the acks and clearing them in a timely manner, otherwise we would stop acking packets altogether.
                    if (sent_packet_data && !sent_packet_data.acked && endpoint.num_acks < endpoint.config.ack_buffer_size) {
                        reliable_log(.VERY_VERBOSE_ONLY, "[%] acked packet %\n", endpoint.config.name, ack_sequence);
                        endpoint.acks[endpoint.num_acks] = ack_sequence;
                        endpoint.num_acks += 1;
                        endpoint.counters[RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_ACKED] += 1;
                        sent_packet_data.acked = true;

                        rtt := cast(float) to_milliseconds(endpoint.time - sent_packet_data.time);
                        assert(rtt >= 0.0);
                        if (endpoint.rtt == 0.0 && rtt > 0.0) || abs(endpoint.rtt - rtt) < 0.00001 {
                            endpoint.rtt = rtt;
                        } else {
                            endpoint.rtt += (rtt - endpoint.rtt) * endpoint.config.rtt_smoothing_factor;
                        }
                    }
                }
                ack_bits >>= 1;
            }
        } else {
            reliable_log(.ERROR, "[%] process packet failed\n", endpoint.config.name);
        }
    } else {
        // fragment packet
        fragment_header := reliable_read_fragment_header(endpoint.config.name, packet_data, endpoint.config.max_fragments, endpoint.config.fragment_size);

        if fragment_header.fragment_header_bytes == 0 {
            reliable_log(.VERY_VERBOSE_ONLY, "[%] ignoring invalid fragment. could not read fragment header\n", endpoint.config.name);
            endpoint.counters[RELIABLE_ENDPOINT_COUNTER_NUM_FRAGMENTS_INVALID] += 1;
            return;
        }

        reassembly_data := cast(*reliable_fragment_reassembly_data_t) reliable_sequence_buffer_find(endpoint.fragment_reassembly, fragment_header.sequence);

        if !reassembly_data {
            reassembly_data = cast(*reliable_fragment_reassembly_data_t) reliable_sequence_buffer_insert(endpoint.fragment_reassembly, fragment_header.sequence, cleanup = true);

            if !reassembly_data {
                reliable_log(.ERROR, "[%] ignoring invalid fragment. could not insert in reassembly buffer (stale)\n", endpoint.config.name);
                endpoint.counters[RELIABLE_ENDPOINT_COUNTER_NUM_FRAGMENTS_INVALID] += 1;
                return;
            }

            reliable_sequence_buffer_advance(endpoint.received_packets, fragment_header.sequence);

            packet_buffer_size: int = RELIABLE_MAX_PACKET_HEADER_BYTES + fragment_header.num_fragments * endpoint.config.fragment_size;

            reassembly_data.sequence = fragment_header.sequence;
            reassembly_data.num_fragments_total = fragment_header.num_fragments;
            reassembly_data.packet_data = NewArray(packet_buffer_size, u8);
        }

        if fragment_header.num_fragments != reassembly_data.num_fragments_total {
            reliable_log(.ERROR,
                "[%] ignoring invalid fragment. fragment count mismatch. expected %, got %\n",
                endpoint.config.name, reassembly_data.num_fragments_total, fragment_header.num_fragments);
            endpoint.counters[RELIABLE_ENDPOINT_COUNTER_NUM_FRAGMENTS_INVALID] += 1;
            return;
        }

        if reassembly_data.fragment_received[fragment_header.fragment_id] {
            reliable_log(.ERROR,
                "[%] ignoring fragment % of packet %. fragment already received\n",
                endpoint.config.name, fragment_header.fragment_id, fragment_header.sequence);
            return;
        }

        reliable_log(.VERY_VERBOSE_ONLY,
            "[%] received fragment % of packet % (%/%)\n",
            endpoint.config.name, fragment_header.fragment_id, fragment_header.sequence, reassembly_data.num_fragments_received + 1, fragment_header.num_fragments);

        reassembly_data.num_fragments_received += 1;
        reassembly_data.fragment_received[fragment_header.fragment_id] = 1;

        fragment_body := packet_data;
        fragment_body.data += fragment_header.fragment_header_bytes;
        fragment_body.count -= fragment_header.fragment_header_bytes;

        reliable_store_fragment_data(reassembly_data,
                                     fragment_header.sequence,
                                     fragment_header.ack,
                                     fragment_header.ack_bits,
                                     fragment_header.fragment_id,
                                     endpoint.config.fragment_size,
                                     fragment_body);

        if reassembly_data.num_fragments_received == reassembly_data.num_fragments_total {
            reliable_log(.VERY_VERBOSE_ONLY, "[%] completed reassembly of packet %\n", endpoint.config.name, fragment_header.sequence);

            packet_body := reassembly_data.packet_data;
            packet_body.data += RELIABLE_MAX_PACKET_HEADER_BYTES - reassembly_data.packet_header_bytes;
            packet_body.count = reassembly_data.packet_header_bytes + reassembly_data.packet_data.count;

            reliable_endpoint_receive_packet(endpoint, packet_body);

            reliable_sequence_buffer_remove(endpoint.fragment_reassembly, fragment_header.sequence, cleanup = true);
        }

        endpoint.counters[RELIABLE_ENDPOINT_COUNTER_NUM_FRAGMENTS_RECEIVED] += 1;
    }
}

// NOTE(dlb): What is this point of this method? Just call free()..
// reliable_endpoint_free_packet :: (endpoint: *reliable_endpoint_t, packet: *void) {
//     assert(endpoint != null);
//     assert(packet);

//     free(packet);
// }

reliable_endpoint_get_acks :: (endpoint: *reliable_endpoint_t) -> [] u16 {
    assert(endpoint != null);

    acks := endpoint.acks;
    acks.count = endpoint.num_acks;
    return acks;
}

reliable_endpoint_clear_acks :: (endpoint: *reliable_endpoint_t) {
    assert(endpoint != null);

    endpoint.num_acks = 0;
}

reliable_endpoint_reset :: (endpoint: *reliable_endpoint_t) {
    assert(endpoint != null);

    // NOTE(dlb): The original code doesn't reset `time` or any of the statistics. Seems like a bug to me.
    endpoint.time                    = APOLLO_ZERO;
    endpoint.rtt                     = 0;
    endpoint.packet_loss             = 0;
    endpoint.sent_bandwidth_kbps     = 0;
    endpoint.received_bandwidth_kbps = 0;
    endpoint.acked_bandwidth_kbps    = 0;

    endpoint.num_acks = 0;
    array_zero(endpoint.acks);

    endpoint.sequence = 0;

    reliable_sequence_buffer_reset(endpoint.sent_packets);
    reliable_sequence_buffer_reset(endpoint.received_packets);

    for 0..endpoint.config.fragment_reassembly_buffer_size-1 {
        reassembly_data := reliable_sequence_buffer_at_index(endpoint.fragment_reassembly, it);
        if reassembly_data != null && reassembly_data.packet_data.data != null {
            array_reset(*reassembly_data.packet_data);
        }
    }
    reliable_sequence_buffer_reset(endpoint.fragment_reassembly);

    array_zero(endpoint.counters);
}

reliable_endpoint_update :: (endpoint: *reliable_endpoint_t, time: Apollo_Time) {
    assert(endpoint != null);

    endpoint.time = time;

    // calculate packet loss
    {
        base_sequence := cast (int) endpoint.sent_packets.sequence - endpoint.config.sent_packets_buffer_size + 1 + 0xFFFF;
        num_dropped := 0.0;
        num_samples := endpoint.config.sent_packets_buffer_size / 2;
        for 0..num_samples-1 {
            sequence := cast,no_check(u16) (base_sequence + it);
            sent_packet_data := cast(*reliable_sent_packet_data_t) reliable_sequence_buffer_find(endpoint.sent_packets, sequence);
            if sent_packet_data && !sent_packet_data.acked {
                num_dropped += 1;
            }
        }
        packet_loss: float = num_dropped / num_samples * 100;
        if abs(endpoint.packet_loss - packet_loss) > 0.00001 {
            endpoint.packet_loss += (packet_loss - endpoint.packet_loss) * endpoint.config.packet_loss_smoothing_factor;
        } else {
            endpoint.packet_loss = packet_loss;
        }
    }

    // calculate sent bandwidth
    {
        base_sequence := cast (int) endpoint.sent_packets.sequence - endpoint.config.sent_packets_buffer_size + 1 + 0xFFFF;
        bytes_sent := 0.0;
        start_time := APOLLO_MAX;  // was FLT_MAX
        finish_time := APOLLO_ZERO;
        num_samples := endpoint.config.sent_packets_buffer_size / 2;
        for 0..num_samples-1 {
            sequence := cast,no_check(u16) (base_sequence + it);
            sent_packet_data := cast(*reliable_sent_packet_data_t) reliable_sequence_buffer_find(endpoint.sent_packets, sequence);
            if !sent_packet_data {
                continue;
            }
            bytes_sent += sent_packet_data.packet_bytes;
            if sent_packet_data.time < start_time {
                start_time = sent_packet_data.time;
            }
            if sent_packet_data.time > finish_time {
                finish_time = sent_packet_data.time;
            }
        }
        if start_time != APOLLO_MAX && finish_time != APOLLO_ZERO {
            sent_bandwidth_kbps := bytes_sent / to_milliseconds(finish_time - start_time) * 8.0 / 1000.0;
            if abs(endpoint.sent_bandwidth_kbps - sent_bandwidth_kbps) > 0.00001 {
                endpoint.sent_bandwidth_kbps += (sent_bandwidth_kbps - endpoint.sent_bandwidth_kbps) * endpoint.config.bandwidth_smoothing_factor;
            } else {
                endpoint.sent_bandwidth_kbps = sent_bandwidth_kbps;
            }
        }
    }

    // calculate received bandwidth
    {
        base_sequence := cast (int) endpoint.received_packets.sequence - endpoint.config.received_packets_buffer_size + 1 + 0xFFFF;
        bytes_sent := 0.0;
        start_time := APOLLO_MAX;
        finish_time := APOLLO_ZERO;
        num_samples := endpoint.config.received_packets_buffer_size / 2;
        for 0..num_samples-1 {
            sequence := cast,no_check(u16) (base_sequence + it);
            received_packet_data := cast(*reliable_received_packet_data_t) reliable_sequence_buffer_find(endpoint.received_packets, sequence);
            if !received_packet_data {
                continue;
            }
            bytes_sent += received_packet_data.packet_bytes;
            if received_packet_data.time < start_time {
                start_time = received_packet_data.time;
            }
            if received_packet_data.time > finish_time {
                finish_time = received_packet_data.time;
            }
        }
        if start_time != APOLLO_MAX && finish_time != APOLLO_ZERO {
            received_bandwidth_kbps := bytes_sent / to_milliseconds(finish_time - start_time) * 8.0 / 1000.0;
            if abs(endpoint.received_bandwidth_kbps - received_bandwidth_kbps) > 0.00001 {
                endpoint.received_bandwidth_kbps += (received_bandwidth_kbps - endpoint.received_bandwidth_kbps) * endpoint.config.bandwidth_smoothing_factor;
            } else {
                endpoint.received_bandwidth_kbps = received_bandwidth_kbps;
            }
        }
    }

    // calculate acked bandwidth
    {
        base_sequence := cast (int) endpoint.sent_packets.sequence - endpoint.config.sent_packets_buffer_size + 1 + 0xFFFF;
        bytes_sent := 0.0;
        start_time := APOLLO_MAX;
        finish_time := APOLLO_ZERO;
        num_samples := endpoint.config.sent_packets_buffer_size / 2;
        for 0..num_samples-1 {
            sequence := cast,no_check(u16) (base_sequence + it);
            sent_packet_data := cast(*reliable_sent_packet_data_t) reliable_sequence_buffer_find(endpoint.sent_packets, sequence);
            if !sent_packet_data || !sent_packet_data.acked {
                continue;
            }
            bytes_sent += sent_packet_data.packet_bytes;
            if sent_packet_data.time < start_time {
                start_time = sent_packet_data.time;
            }
            if sent_packet_data.time > finish_time {
                finish_time = sent_packet_data.time;
            }
        }
        if start_time != APOLLO_MAX && finish_time != APOLLO_ZERO {
            acked_bandwidth_kbps := bytes_sent / to_milliseconds(finish_time - start_time) * 8.0 / 1000.0;
            if abs(endpoint.acked_bandwidth_kbps - acked_bandwidth_kbps) > 0.00001 {
                endpoint.acked_bandwidth_kbps += (acked_bandwidth_kbps - endpoint.acked_bandwidth_kbps) * endpoint.config.bandwidth_smoothing_factor;
            } else {
                endpoint.acked_bandwidth_kbps = acked_bandwidth_kbps;
            }
        }
    }
}

reliable_endpoint_rtt :: inline (endpoint: *reliable_endpoint_t) -> float {
    assert(endpoint != null);

    return endpoint.rtt;
}

reliable_endpoint_packet_loss :: inline (endpoint: *reliable_endpoint_t ) -> float {
    assert(endpoint != null);

    return endpoint.packet_loss;
}

reliable_endpoint_bandwidth :: inline (endpoint: *reliable_endpoint_t) -> sent_bandwidth_kbps: float, received_bandwidth_kbps: float, acked_bandwidth_kpbs: float {
    assert(endpoint != null);

    return endpoint.sent_bandwidth_kbps, endpoint.received_bandwidth_kbps, endpoint.acked_bandwidth_kbps;
}

reliable_endpoint_counters :: inline (endpoint: *reliable_endpoint_t) -> [RELIABLE_ENDPOINT_NUM_COUNTERS] u64 {
    assert(endpoint != null);

    return endpoint.counters;
}

#scope_module

#import "Basic";
#import "Math";
#import "Trivial";

APOLLO_ZERO :: Apollo_Time.{0, 0};
APOLLO_MAX :: Apollo_Time.{0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF};

reliable_log :: (flags: Log_Flags, format_string: string, args: .. Any, loc := #caller_location) {
    #if ENABLE_LOGGING {
        log(format_string, ..args, loc, flags,, temp);
    }
}

reliable_sequence_greater_than :: (s1: u16, s2: u16) -> bool {
    return ((s1 > s2) && (s1 - s2 <= 32768)) ||
           ((s1 < s2) && (s2 - s1  > 32768));
}

reliable_sequence_less_than :: (s1: u16, s2: u16) -> bool {
    return reliable_sequence_greater_than(s2, s1);
}

reliable_sent_packet_data_t :: struct {
    time: Apollo_Time;
    acked: bool;
    packet_bytes: int;
};

reliable_received_packet_data_t :: struct {
    time: Apollo_Time;
    packet_bytes: int;
};

// TODO(dlb): This could maybe be polymorphic to make entry_data strongly typed. I tried it quickly, but it made a mess.
reliable_sequence_buffer_t :: struct {
    sequence: u16;
    num_entries: int;
    entry_stride: int;
    entry_sequence: [] u32;
    entry_data: [] u8;
};

reliable_sequence_buffer_create :: (num_entries: int, entry_stride: int) -> *reliable_sequence_buffer_t {
    assert(num_entries > 0);
    assert(entry_stride > 0);

    sequence_buffer := New(reliable_sequence_buffer_t);

    sequence_buffer.sequence = 0;
    sequence_buffer.num_entries = num_entries;
    sequence_buffer.entry_stride = entry_stride;

    sequence_buffer.entry_sequence = NewArray(num_entries, u32, initialized = false);
    assert(sequence_buffer.entry_sequence.count > 0);

    sequence_buffer.entry_data = NewArray(num_entries * entry_stride, u8);
    assert(sequence_buffer.entry_data.count > 0);

    array_fill_byte(sequence_buffer.entry_sequence, 0xFF);

    return sequence_buffer;
}

reliable_sequence_buffer_destroy :: (sequence_buffer: *reliable_sequence_buffer_t) {
    assert(sequence_buffer != null);

    array_free(sequence_buffer.entry_sequence);
    array_free(sequence_buffer.entry_data);
    free(sequence_buffer);
}

reliable_sequence_buffer_reset :: (sequence_buffer: *reliable_sequence_buffer_t) {
    assert(sequence_buffer != null);

    sequence_buffer.sequence = 0;
    array_fill_byte(sequence_buffer.entry_sequence, 0xFF);
}

reliable_sequence_buffer_remove_entries :: (sequence_buffer: *reliable_sequence_buffer_t, start_sequence: int, finish_sequence: int, $cleanup: bool = false) {
    assert(sequence_buffer != null);

    if finish_sequence < start_sequence {
        finish_sequence += 65536;
    }

    if finish_sequence - start_sequence < sequence_buffer.num_entries {
        for sequence: start_sequence..finish_sequence {
            #if cleanup {
                reliable_fragment_reassembly_data_cleanup(
                    sequence_buffer.entry_data.data + sequence_buffer.entry_stride * (sequence % sequence_buffer.num_entries)
                );
            }
            sequence_buffer.entry_sequence[sequence % sequence_buffer.num_entries] = 0xFFFFFFFF;
        }
    } else {
        for 0..sequence_buffer.num_entries-1 {
            #if cleanup {
                reliable_fragment_reassembly_data_cleanup(
                    sequence_buffer.entry_data.data + sequence_buffer.entry_stride * it
                );
            }
            sequence_buffer.entry_sequence[it] = 0xFFFFFFFF;
        }
    }
}

reliable_sequence_buffer_test_insert :: (sequence_buffer: *reliable_sequence_buffer_t, sequence: u16) -> bool {
    return reliable_sequence_greater_than(sequence, sequence_buffer.sequence - cast(u16) sequence_buffer.num_entries);
}

reliable_sequence_buffer_insert :: (sequence_buffer: *reliable_sequence_buffer_t, sequence: u16, $cleanup: bool = false) -> *void {
    assert(sequence_buffer != null);

    if reliable_sequence_less_than(sequence, sequence_buffer.sequence - (cast(u16) sequence_buffer.num_entries)) {
        return null;
    }

    if reliable_sequence_greater_than(sequence + 1, sequence_buffer.sequence) {
        reliable_sequence_buffer_remove_entries(sequence_buffer, sequence_buffer.sequence, sequence, cleanup);
        sequence_buffer.sequence = sequence + 1;
    }

    index: int = sequence % sequence_buffer.num_entries;
    #if cleanup {
        if sequence_buffer.entry_sequence[index] != 0xFFFFFFFF {
            reliable_fragment_reassembly_data_cleanup(sequence_buffer.entry_data.data + sequence_buffer.entry_stride * (sequence % sequence_buffer.num_entries));
        }
    }
    sequence_buffer.entry_sequence[index] = sequence;
    return sequence_buffer.entry_data.data + index * sequence_buffer.entry_stride;
}

reliable_sequence_buffer_advance :: (sequence_buffer: *reliable_sequence_buffer_t, sequence: u16, $cleanup: bool = false)
{
    assert(sequence_buffer != null);

    if reliable_sequence_greater_than(sequence + 1, sequence_buffer.sequence) {
        reliable_sequence_buffer_remove_entries(sequence_buffer, sequence_buffer.sequence, sequence, cleanup);
        sequence_buffer.sequence = sequence + 1;
    }
}

// NOTE(dlb): cleanup = false variant is never actually called
reliable_sequence_buffer_remove :: (sequence_buffer: *reliable_sequence_buffer_t, sequence: u16, $cleanup: bool = false) {
    assert(sequence_buffer != null);

    index: int = sequence % sequence_buffer.num_entries;
    #if cleanup {
        if sequence_buffer.entry_sequence[index] != 0xFFFFFFFF {
            reliable_fragment_reassembly_data_cleanup(sequence_buffer.entry_data.data + sequence_buffer.entry_stride * index);
        }
    }
    sequence_buffer.entry_sequence[index] = 0xFFFFFFFF;
}

reliable_sequence_buffer_available :: (sequence_buffer: *reliable_sequence_buffer_t, sequence: u16) -> bool {
    assert(sequence_buffer != null);

    return sequence_buffer.entry_sequence[sequence % sequence_buffer.num_entries] == 0xFFFFFFFF;
}

reliable_sequence_buffer_exists :: (sequence_buffer: *reliable_sequence_buffer_t, sequence: u16) -> bool {
    assert(sequence_buffer != null);

    return sequence_buffer.entry_sequence[sequence % sequence_buffer.num_entries] == cast(u32) sequence;
}

reliable_sequence_buffer_find :: (sequence_buffer: *reliable_sequence_buffer_t, sequence: u16) -> *void {
    assert(sequence_buffer != null);

    index: int = sequence % sequence_buffer.num_entries;
    return ifx sequence_buffer.entry_sequence[index] == cast(u32) sequence
        then sequence_buffer.entry_data.data + index * sequence_buffer.entry_stride
        else null;
}

reliable_sequence_buffer_at_index :: (sequence_buffer: *reliable_sequence_buffer_t, index: int) -> *reliable_fragment_reassembly_data_t {
    assert(sequence_buffer != null);
    assert(index >= 0);
    assert(index < sequence_buffer.num_entries);

    return ifx sequence_buffer.entry_sequence[index] != 0xFFFFFFFF
        then cast (*reliable_fragment_reassembly_data_t) (sequence_buffer.entry_data.data + index * sequence_buffer.entry_stride)
        else null;
}

reliable_sequence_buffer_generate_ack_bits :: (sequence_buffer: *reliable_sequence_buffer_t) -> ack: u16, ack_bits: u32 {
    assert(sequence_buffer != null);

    ack: u16 = sequence_buffer.sequence - 1;
    ack_bits: u32 = 0;
    mask: u32 = 1;

    for 0..31 {
        sequence := ack - (cast(u16) it);
        if reliable_sequence_buffer_exists(sequence_buffer, sequence) {
            ack_bits |= mask;
        }
        mask <<= 1;
    }

    return ack, ack_bits;
}

// ---------------------------------------------------------------

reliable_write_uint8 :: (p: **u8, value: u8) {
    p.*.* = value;
    p.* += 1;
}

reliable_write_uint16 :: (p: **u8, value: u16) {
    p.*[0] = cast(u8) (value & 0xFF);
    p.*[1] = cast(u8) (value >> 8);
    p.* += 2;
}

reliable_write_uint32 :: (p: **u8, value: u32) {
    p.*[0] = cast(u8) (value & 0xFF);
    p.*[1] = cast(u8) ((value >> 8 ) & 0xFF);
    p.*[2] = cast(u8) ((value >> 16) & 0xFF);
    p.*[3] = cast(u8) (value >> 24);
    p.* += 4;
}

reliable_write_uint64 :: (p: **u8, value: u64) {
    p.*[0] = cast(u8) (value & 0xFF);
    p.*[1] = cast(u8) ((value >> 8 ) & 0xFF);
    p.*[2] = cast(u8) ((value >> 16) & 0xFF);
    p.*[3] = cast(u8) ((value >> 24) & 0xFF);
    p.*[4] = cast(u8) ((value >> 32) & 0xFF);
    p.*[5] = cast(u8) ((value >> 40) & 0xFF);
    p.*[6] = cast(u8) ((value >> 48) & 0xFF);
    p.*[7] = cast(u8) (value >> 56);
    p.* += 8;
}

reliable_write_bytes :: (p: **u8, byte_array: *u8, num_bytes: int) {
    for 0..num_bytes-1 {
        reliable_write_uint8(p, byte_array[it]);
    }
}

reliable_read_uint8 :: (p: **u8) -> u8 {
    value := p.*.*;
    p.* += 1;
    return value;
}

reliable_read_uint16 :: (p: **u8) -> u16 {
    value: u16 = p.*[0];
    value |= (cast(u16) p.*[1]) << 8;
    p.* += 2;
    return value;
}

reliable_read_uint32 :: (p: **u8) -> u32 {
    value: u32 = p.*[0];
    value |= (cast(u32) p.*[1]) << 8;
    value |= (cast(u32) p.*[2]) << 16;
    value |= (cast(u32) p.*[3]) << 24;
    p.* += 4;
    return value;
}

reliable_read_uint64 :: (p: **u8) -> u64 {
    value: u64 = p.*[0];
    value |= (cast(u64) p.*[1]) << 8;
    value |= (cast(u64) p.*[2]) << 16;
    value |= (cast(u64) p.*[3]) << 24;
    value |= (cast(u64) p.*[4]) << 32;
    value |= (cast(u64) p.*[5]) << 40;
    value |= (cast(u64) p.*[6]) << 48;
    value |= (cast(u64) p.*[7]) << 56;
    p.* += 8;
    return value;
}

reliable_read_bytes :: (p: **u8, byte_array: *u8, num_bytes: int) {
    for 0..num_bytes-1 {
        byte_array[it] = reliable_read_uint8(p);
    }
}

// ---------------------------------------------------------------

reliable_fragment_reassembly_data_t :: struct {
    sequence: u16;
    ack: u16;
    ack_bits: u32;
    num_fragments_received: int;
    num_fragments_total: int;
    packet_data: [] u8;
    packet_header_bytes: int;
    fragment_received: [256] u8;
};

reliable_fragment_reassembly_data_cleanup :: (data: *void) {
    reassembly_data := cast(*reliable_fragment_reassembly_data_t) data;
    free(reassembly_data.packet_data.data);
    reassembly_data.* = .{};
}

// ---------------------------------------------------------------

reliable_write_packet_header :: (packet_data: [] u8, sequence: u16, ack: u16, ack_bits: u32) -> int {
    p := packet_data.data;

    prefix_byte: u8 = 0;

    if (ack_bits & 0x000000FF) != 0x000000FF prefix_byte |= (1 << 1);
    if (ack_bits & 0x0000FF00) != 0x0000FF00 prefix_byte |= (1 << 2);
    if (ack_bits & 0x00FF0000) != 0x00FF0000 prefix_byte |= (1 << 3);
    if (ack_bits & 0xFF000000) != 0xFF000000 prefix_byte |= (1 << 4);

    sequence_difference: int = (cast(int) sequence) - ack;
    if sequence_difference < 0 {
        sequence_difference += 65536;
    }
    if sequence_difference <= 255 {
        prefix_byte |= (1 << 5);
    }

    reliable_write_uint8(*p, prefix_byte);
    reliable_write_uint16(*p, sequence);

    if sequence_difference <= 255
        reliable_write_uint8(*p, cast(u8) sequence_difference);
    else
        reliable_write_uint16(*p, ack);

    if (ack_bits & 0x000000FF) != 0x000000FF reliable_write_uint8(*p, cast(u8) (ack_bits & 0x000000FF));
    if (ack_bits & 0x0000FF00) != 0x0000FF00 reliable_write_uint8(*p, cast(u8) (ack_bits & 0x0000FF00) >> 8);
    if (ack_bits & 0x00FF0000) != 0x00FF0000 reliable_write_uint8(*p, cast(u8) (ack_bits & 0x00FF0000) >> 16);
    if (ack_bits & 0xFF000000) != 0xFF000000 reliable_write_uint8(*p, cast(u8) (ack_bits & 0xFF000000) >> 24);

    header_size := pointer_diff(p, packet_data.data);
    assert(header_size <= RELIABLE_MAX_PACKET_HEADER_BYTES);

    return header_size;
}

reliable_read_packet_header :: (name: string, packet_data: [] u8) -> header_size: int = -1, sequence: u16 = 0, ack: u16 = 0, ack_bits: u32 = 0 {
    if packet_data.count < 3 {
        reliable_log(.VERY_VERBOSE_ONLY, "[%] packet too small for packet header (1)\n", name);
        return;
    }

    p: *u8 = packet_data.data;
    prefix_byte: u8 = reliable_read_uint8(*p);

    if (prefix_byte & 1) != 0 {
        reliable_log(.VERY_VERBOSE_ONLY, "[%] prefix byte does not indicate a regular packet\n", name);
        return;
    }

    sequence: u16 = reliable_read_uint16(*p);
    ack: u16;

    if prefix_byte & (1 << 5) {
        if packet_data.count < 3 + 1 {
            reliable_log(.VERY_VERBOSE_ONLY, "[%] packet too small for packet header (2)\n", name);
            return;
        }
        sequence_difference: u8 = reliable_read_uint8(*p);
        ack = sequence - sequence_difference;
    } else {
        if packet_data.count < 3 + 2 {
            reliable_log(.VERY_VERBOSE_ONLY, "[%] packet too small for packet header (3)\n", name);
            return;
        }
        ack = reliable_read_uint16(*p);
    }

    expected_bytes: int = 0;
    for 1..4 {
        if prefix_byte & (1 << it)
            expected_bytes += 1;
    }
    if packet_data.count < pointer_diff(p, packet_data.data) + expected_bytes {
        reliable_log(.VERY_VERBOSE_ONLY, "[%] packet too small for packet header (4)\n", name);
        return;
    }

    ack_bits: u32 = 0xFFFFFFFF;

    if prefix_byte & (1 << 1) {
        ack_bits &= 0xFFFFFF00;
        ack_bits |= cast(u32) reliable_read_uint8(*p);
    }

    if prefix_byte & (1 << 2) {
        ack_bits &= 0xFFFF00FF;
        ack_bits |= (cast(u32) reliable_read_uint8(*p)) << 8;
    }

    if prefix_byte & (1 << 3) {
        ack_bits &= 0xFF00FFFF;
        ack_bits |= (cast(u32) reliable_read_uint8(*p)) << 16;
    }

    if prefix_byte & (1 << 4) {
        ack_bits &= 0x00FFFFFF;
        ack_bits |= (cast(u32) reliable_read_uint8(*p)) << 24;
    }

    return pointer_diff(p, packet_data.data), sequence, ack, ack_bits;
}

reliable_fragment_header_t :: struct {
    fragment_header_bytes: int;
    fragment_id: int;
    num_fragments: int;
    fragment_bytes: int;

    sequence: u16;
    ack: u16;
    ack_bits: u32;
}

reliable_read_fragment_header :: (name: string, packet_data: [] u8, max_fragments: int, fragment_size: int) -> reliable_fragment_header_t {
    fragment_header: reliable_fragment_header_t;

    if packet_data.count < RELIABLE_FRAGMENT_HEADER_BYTES {
        reliable_log(.VERY_VERBOSE_ONLY, "[%] packet is too small to read fragment header\n", name);
        return fragment_header;
    }

    p: *u8 = packet_data.data;

    prefix_byte: u8 = reliable_read_uint8(*p);
    if prefix_byte != 1 {
        reliable_log(.VERY_VERBOSE_ONLY, "[%] prefix byte is not a fragment\n", name);
        return fragment_header;
    }

    fragment_header.sequence = reliable_read_uint16(*p);
    fragment_header.fragment_id = cast(int) reliable_read_uint8(*p);
    fragment_header.num_fragments = (cast(int) reliable_read_uint8(*p)) + 1;

    if fragment_header.num_fragments > max_fragments {
        reliable_log(.VERY_VERBOSE_ONLY, "[%] num fragments % outside of range of max fragments %\n", name, fragment_header.num_fragments, max_fragments);
        return fragment_header;
    }

    if fragment_header.fragment_id >= fragment_header.num_fragments {
        reliable_log(.VERY_VERBOSE_ONLY, "[%] fragment id % outside of range of num fragments %\n", name, fragment_header.fragment_id, fragment_header.num_fragments);
        return fragment_header;
    }

    fragment_header.fragment_bytes = packet_data.count - RELIABLE_FRAGMENT_HEADER_BYTES;

    packet_sequence: u16;
    packet_ack: u16;
    packet_ack_bits: u32;

    if fragment_header.fragment_id == 0 {
        packet_body := packet_data;
        packet_body.data += RELIABLE_FRAGMENT_HEADER_BYTES;
        packet_body.count -= RELIABLE_FRAGMENT_HEADER_BYTES;

        packet_header_bytes: int;
        packet_header_bytes, packet_sequence, packet_ack, packet_ack_bits = reliable_read_packet_header(name, packet_body);

        if packet_header_bytes < 0 {
            reliable_log(.VERY_VERBOSE_ONLY, "[%] bad packet header in fragment\n", name);
            return fragment_header;
        }

        if packet_sequence != fragment_header.sequence {
            reliable_log(.VERY_VERBOSE_ONLY, "[%] bad packet sequence in fragment. expected %, got %\n", name, fragment_header.sequence, packet_sequence);
            return fragment_header;
        }

        fragment_header.fragment_bytes = packet_data.count - packet_header_bytes - RELIABLE_FRAGMENT_HEADER_BYTES;
    }

    fragment_header.ack = packet_ack;
    fragment_header.ack_bits = packet_ack_bits;

    if fragment_header.fragment_bytes > fragment_size {
        reliable_log(.VERY_VERBOSE_ONLY, "[%] fragment bytes % > fragment size %\n", name, fragment_header.fragment_bytes, fragment_size);
        return fragment_header;
    }

    if fragment_header.fragment_id != fragment_header.num_fragments - 1 && fragment_header.fragment_bytes != fragment_size {
        reliable_log(.VERY_VERBOSE_ONLY,
            "[%] fragment % is % bytes, which is not the expected fragment size %\n",
            name, fragment_header.fragment_id, fragment_header.fragment_bytes, fragment_size);
        return fragment_header;
    }

    fragment_header.fragment_header_bytes = pointer_diff(p, packet_data.data);
    return fragment_header;
}

reliable_store_fragment_data :: (reassembly_data: *reliable_fragment_reassembly_data_t, sequence: u16, ack: u16, ack_bits: u32,
                                 fragment_id: int, fragment_size: int, fragment_data: [] u8) {
    frag_data := fragment_data;

    if fragment_id == 0 {
        packet_header: [RELIABLE_MAX_PACKET_HEADER_BYTES] u8;

        reassembly_data.packet_header_bytes = reliable_write_packet_header(packet_header, sequence, ack, ack_bits);

        // NOTE(dlb): I don't really understand why it's writing the packet header at the *end* of the MAX_PACKET_HEADER_BYTES section.
        // This is only for the first fragment, so I guess it just doesn't want to make a variable-width header? Why put it at the end though?
        memcpy(
            reassembly_data.packet_data.data + RELIABLE_MAX_PACKET_HEADER_BYTES - reassembly_data.packet_header_bytes,
            packet_header.data,
            reassembly_data.packet_header_bytes
        );

        frag_data.data += reassembly_data.packet_header_bytes;
        frag_data.count -= reassembly_data.packet_header_bytes;
    }

    if fragment_id == reassembly_data.num_fragments_total - 1 {
        reassembly_data.packet_data.count = (reassembly_data.num_fragments_total - 1) * fragment_size + frag_data.count;
    }

    memcpy(
        reassembly_data.packet_data.data + RELIABLE_MAX_PACKET_HEADER_BYTES + fragment_id * fragment_size,
        frag_data.data,
        frag_data.count
    );
}
