reliable_test :: () {
    log("\n--- Reliable -------------------------------------------------------------------\n");
    log("Running tests...\n");
    TEST(test_sequence_buffer);
    TEST(test_generate_ack_bits);
    TEST(test_packet_header);
    TEST(test_acks);
    TEST(test_acks_packet_loss);
    TEST(test_packets);
    TEST(test_large_packets);
    TEST(test_sequence_buffer_rollover);
    TEST(test_fragment_cleanup);
    log("Passed!\n");
    reset_temporary_storage();
}

#scope_file

#import "Assertive";

TEST :: (test: (), $call := #caller_code) {
    assert_test(test, ENABLE_LOGGING, call);
}

test_sequence_data_t :: struct {
    sequence: u16;
}

TEST_SEQUENCE_BUFFER_SIZE :: 256;

test_sequence_buffer :: () {
    sequence_buffer := reliable_sequence_buffer_create(TEST_SEQUENCE_BUFFER_SIZE, size_of(test_sequence_data_t));

    assert_not_null(sequence_buffer);
    assert_equal(sequence_buffer.sequence, 0);
    assert_equal(sequence_buffer.num_entries, TEST_SEQUENCE_BUFFER_SIZE);
    assert_equal(sequence_buffer.entry_stride, size_of(test_sequence_data_t));

    // Check that all buffer slots are initially empty
    for 0..TEST_SEQUENCE_BUFFER_SIZE-1 {
        assert_null(reliable_sequence_buffer_find(sequence_buffer, (cast(u16) it)));
    }

    // Insert enough things to overwrite the buffer entries multiple times, ensuring sequence # keeps going up
    for 0..TEST_SEQUENCE_BUFFER_SIZE*4 {
        entry := cast(*test_sequence_data_t) reliable_sequence_buffer_insert(sequence_buffer, cast(u16) it);
        assert(entry != null);
        entry.sequence = cast(u16) it;
        assert_equal(sequence_buffer.sequence, cast(u16) it + 1);
    }

    // Check that older sequenced things do not get inserted into the buffer
    for 0..TEST_SEQUENCE_BUFFER_SIZE {
        entry := cast(*test_sequence_data_t) reliable_sequence_buffer_insert(sequence_buffer, cast(u16) it);
        assert_null(entry);
    }

    // Check that the N (where N == BUFFER_SIZE) most recent entries are in the buffer and have the last N sequence numbers
    sequence := TEST_SEQUENCE_BUFFER_SIZE * 4;
    for 0..TEST_SEQUENCE_BUFFER_SIZE-1 {
        entry := cast(*test_sequence_data_t) reliable_sequence_buffer_find(sequence_buffer, cast(u16) sequence);
        assert_not_null(entry);
        assert_equal(entry.sequence, cast(u16) sequence);
        sequence -= 1;
    }

    reliable_sequence_buffer_reset(sequence_buffer);

    assert_not_null(sequence_buffer);
    assert_equal(sequence_buffer.sequence, 0);
    assert_equal(sequence_buffer.num_entries, TEST_SEQUENCE_BUFFER_SIZE);
    assert_equal(sequence_buffer.entry_stride, size_of(test_sequence_data_t));

    // Check that all of the entries were cleared
    for 0..TEST_SEQUENCE_BUFFER_SIZE-1 {
        assert_null(reliable_sequence_buffer_find(sequence_buffer, cast(u16) it));
    }

    reliable_sequence_buffer_destroy(sequence_buffer);
}

test_generate_ack_bits :: () {
     sequence_buffer := reliable_sequence_buffer_create(TEST_SEQUENCE_BUFFER_SIZE, size_of(test_sequence_data_t));

    ack, ack_bits := reliable_sequence_buffer_generate_ack_bits(sequence_buffer);
    assert_equal(ack, 0xFFFF);
    assert_equal(ack_bits, 0);

    for 0..TEST_SEQUENCE_BUFFER_SIZE {
        reliable_sequence_buffer_insert(sequence_buffer, cast(u16) it);
    }

    ack, ack_bits = reliable_sequence_buffer_generate_ack_bits(sequence_buffer);
    assert_equal(ack, TEST_SEQUENCE_BUFFER_SIZE);
    assert_equal(ack_bits, 0xFFFFFFFF);

    reliable_sequence_buffer_reset(sequence_buffer);

    input_acks: [] u16 = .[ 1, 5, 9, 11 ];
    for input_acks {
        reliable_sequence_buffer_insert(sequence_buffer, it);
    }

    ack, ack_bits = reliable_sequence_buffer_generate_ack_bits(sequence_buffer);

    assert_equal(ack, 11);
    assert_equal(ack_bits, ( 1 | (1<<(11-9)) | (1<<(11-5)) | (1<<(11-1)) ));

    reliable_sequence_buffer_destroy(sequence_buffer);
}

test_packet_header :: () {
    write_sequence: u16;
    write_ack: u16;
    write_ack_bits: u32;

    packet_data: [RELIABLE_MAX_PACKET_HEADER_BYTES] u8;

    // worst case, sequence and ack are far apart, no packets acked.

    write_sequence = 10000;
    write_ack = 100;
    write_ack_bits = 0;

    bytes_written := reliable_write_packet_header(packet_data, write_sequence, write_ack, write_ack_bits);
    assert_equal(bytes_written, RELIABLE_MAX_PACKET_HEADER_BYTES);

    bytes_read, read_sequence, read_ack, read_ack_bits := reliable_read_packet_header("test_packet_header", .{ bytes_written, packet_data.data });
    assert_equal(bytes_read, bytes_written);
    assert_equal(read_sequence, write_sequence);
    assert_equal(read_ack, write_ack);
    assert_equal(read_ack_bits, write_ack_bits);

    // rare case. sequence and ack are far apart, significant # of acks are missing

    write_sequence = 10000;
    write_ack = 100;
    write_ack_bits = 0xFEFEFFFE;

    bytes_written = reliable_write_packet_header(packet_data, write_sequence, write_ack, write_ack_bits);
    assert_equal(bytes_written, 1 + 2 + 2 + 3);

    bytes_read, read_sequence, read_ack, read_ack_bits = reliable_read_packet_header("test_packet_header", .{ bytes_written, packet_data.data });
    assert_equal(bytes_read, bytes_written);
    assert_equal(read_sequence, write_sequence);
    assert_equal(read_ack, write_ack);
    assert_equal(read_ack_bits, write_ack_bits);

    // common case under packet loss. sequence and ack are close together, some acks are missing

    write_sequence = 200;
    write_ack = 100;
    write_ack_bits = 0xFFFEFFFF;

    bytes_written = reliable_write_packet_header(packet_data, write_sequence, write_ack, write_ack_bits);
    assert_equal(bytes_written, 1 + 2 + 1 + 1);

    bytes_read, read_sequence, read_ack, read_ack_bits = reliable_read_packet_header("test_packet_header", .{ bytes_written, packet_data.data });
    assert_equal(bytes_read, bytes_written);
    assert_equal(read_sequence, write_sequence);
    assert_equal(read_ack, write_ack);
    assert_equal(read_ack_bits, write_ack_bits);

    // ideal case. no packet loss.

    write_sequence = 200;
    write_ack = 100;
    write_ack_bits = 0xFFFFFFFF;

    bytes_written = reliable_write_packet_header(packet_data, write_sequence, write_ack, write_ack_bits);
    assert_equal(bytes_written, 1 + 2 + 1);

    bytes_read, read_sequence, read_ack, read_ack_bits = reliable_read_packet_header("test_packet_header", .{ bytes_written, packet_data.data });
    assert_equal(bytes_read, bytes_written);
    assert_equal(read_sequence, write_sequence);
    assert_equal(read_ack, write_ack);
    assert_equal(read_ack_bits, write_ack_bits);
}

test_context_t :: struct {
    drop          : bool;
    allow_packets : int = -1;
    sender        : *reliable_endpoint_t;
    receiver      : *reliable_endpoint_t;
}

test_transmit_packet_function :: (_ctx: *void, id: u64, sequence: u16, packet_data: [] u8) {
    ctx := cast (*test_context_t) _ctx;

    if ctx.drop {
        return;
    }

    if ctx.allow_packets >= 0 {
        if ctx.allow_packets == 0 {
            return;
        }

        ctx.allow_packets -= 1;
    }

    if id == 0 {
        reliable_endpoint_receive_packet(ctx.receiver, packet_data);
    } else if id == 1 {
        reliable_endpoint_receive_packet(ctx.sender, packet_data);
    }
}

test_process_packet_function :: (_ctx: *void, id: u64, sequence: u16, packet_data: [] u8) -> bool {
    return true;
}

TEST_ACKS_NUM_ITERATIONS :: 256;

test_acks :: () {
    time := seconds_to_apollo(100);

    ctx: test_context_t;

    sender_config: reliable_config_t;
    receiver_config: reliable_config_t;

    sender_config.ctx = *ctx;
    sender_config.id = 0;
    sender_config.transmit_packet_function = test_transmit_packet_function;
    sender_config.process_packet_function = test_process_packet_function;

    receiver_config.ctx = *ctx;
    receiver_config.id = 1;
    receiver_config.transmit_packet_function = test_transmit_packet_function;
    receiver_config.process_packet_function = test_process_packet_function;

    ctx.sender = reliable_endpoint_create(*sender_config, time);
    ctx.receiver = reliable_endpoint_create(*receiver_config, time);

    delta_time := milliseconds_to_apollo(10);

    for 0..TEST_ACKS_NUM_ITERATIONS-1 {
        dummy_packet: [8] u8;

        reliable_endpoint_send_packet(ctx.sender, dummy_packet);
        reliable_endpoint_send_packet(ctx.receiver, dummy_packet);

        reliable_endpoint_update(ctx.sender, time);
        reliable_endpoint_update(ctx.receiver, time);

        time += delta_time;
    }

    sender_acked_packet: [TEST_ACKS_NUM_ITERATIONS] bool;
    sender_acks := reliable_endpoint_get_acks(ctx.sender);
    for sender_acks {
        if it < TEST_ACKS_NUM_ITERATIONS {
            sender_acked_packet[it] = true;
        }
    }
    for 0..(TEST_ACKS_NUM_ITERATIONS/2)-1 {
        assert_true(sender_acked_packet[it]);
    }

    receiver_acked_packet: [TEST_ACKS_NUM_ITERATIONS] bool;
    receiver_acks := reliable_endpoint_get_acks(ctx.receiver);
    for receiver_acks {
        if it < TEST_ACKS_NUM_ITERATIONS {
            receiver_acked_packet[it] = true;
        }
    }
    for 0..(TEST_ACKS_NUM_ITERATIONS/2)-1 {
        assert_true(receiver_acked_packet[it]);
    }

    reliable_endpoint_destroy(ctx.sender);
    reliable_endpoint_destroy(ctx.receiver);
}

test_acks_packet_loss :: () {
    time := seconds_to_apollo(100);

    ctx: test_context_t;

    sender_config: reliable_config_t;
    receiver_config: reliable_config_t;

    sender_config.ctx = *ctx;
    sender_config.id = 0;
    sender_config.transmit_packet_function = test_transmit_packet_function;
    sender_config.process_packet_function = test_process_packet_function;

    receiver_config.ctx = *ctx;
    receiver_config.id = 1;
    receiver_config.transmit_packet_function = test_transmit_packet_function;
    receiver_config.process_packet_function = test_process_packet_function;

    ctx.sender = reliable_endpoint_create(*sender_config, time);
    ctx.receiver = reliable_endpoint_create(*receiver_config, time);

    delta_time := milliseconds_to_apollo(100);

    for 0..TEST_ACKS_NUM_ITERATIONS-1 {
        dummy_packet: [8] u8;

        ctx.drop = cast(bool) (it % 2);

        reliable_endpoint_send_packet(ctx.sender, dummy_packet);
        reliable_endpoint_send_packet(ctx.receiver, dummy_packet);

        reliable_endpoint_update(ctx.sender, time);
        reliable_endpoint_update(ctx.receiver, time);

        time += delta_time;
    }

    sender_acked_packet: [TEST_ACKS_NUM_ITERATIONS] bool;
    sender_acks := reliable_endpoint_get_acks(ctx.sender);
    for sender_acks {
        if it < TEST_ACKS_NUM_ITERATIONS {
            sender_acked_packet[it] = true;
        }
    }
    for 0..(TEST_ACKS_NUM_ITERATIONS/2)-1 {
        assert_equal(sender_acked_packet[it], cast(bool) ((it+1) % 2));
    }

    receiver_acked_packet: [TEST_ACKS_NUM_ITERATIONS] bool;
    receiver_acks := reliable_endpoint_get_acks(ctx.receiver);
    for receiver_acks {
        if it < TEST_ACKS_NUM_ITERATIONS {
            receiver_acked_packet[it] = true;
        }
    }
    for 0..(TEST_ACKS_NUM_ITERATIONS/2)-1 {
        assert_equal(receiver_acked_packet[it], cast(bool) ((it+1) % 2));
    }

    reliable_endpoint_destroy(ctx.sender);
    reliable_endpoint_destroy(ctx.receiver);
}

TEST_MAX_PACKET_BYTES :: 4 * 1024;

generate_packet_data_with_size :: (sequence: u16, packet_data: [] u8) {
    assert_true(packet_data.count >= 2);
    assert_true(packet_data.count <= TEST_MAX_PACKET_BYTES);

    packet_data.data[0] = cast(u8) (sequence & 0xFF);
    packet_data.data[1] = cast(u8) ((sequence >> 8) & 0xFF);
    for 2..packet_data.count-1 {
        packet_data[it] = cast(u8) ((it + sequence) % 256);
    }
}

generate_packet_data :: (sequence: u16, packet_data: [] u8) -> int {
    packet_bytes := (((cast(int) sequence) * 1023) % (packet_data.count - 2)) + 2;
    generate_packet_data_with_size(sequence, .{ packet_bytes, packet_data.data });
    return packet_bytes;
}

validate_packet_data :: (packet_data: [] u8) {
    assert_true(packet_data.count >= 2);
    assert_true(packet_data.count <= TEST_MAX_PACKET_BYTES);

    sequence: u16 = 0;
    sequence |= cast(u16) packet_data[0];
    sequence |= (cast(u16) packet_data[1]) << 8;
    assert(packet_data.count == (((cast(int)sequence) * 1023) % (TEST_MAX_PACKET_BYTES - 2)) + 2);
    for 2..packet_data.count-1 {
        assert(packet_data[it] == cast(u8) ((it + sequence) % 256));
    }
}

test_process_packet_function_validate :: (ctx: *void, id: u64, sequence: u16, packet_data: [] u8) -> bool {
    assert_true(packet_data.data != null);
    assert_true(packet_data.count > 0);
    assert_true(packet_data.count <= TEST_MAX_PACKET_BYTES);

    validate_packet_data(packet_data);

    return true;
}

generate_packet_data_large :: (packet_data: [] u8) -> int {
    data_bytes := TEST_MAX_PACKET_BYTES - 2;
    assert_true(data_bytes >= 2);
    assert_true(data_bytes <= (1 << 16));

    packet_data.data[0] = cast(u8) (data_bytes & 0xFF);
    packet_data.data[1] = cast(u8) ((data_bytes >> 8) & 0xFF);
    for 2..data_bytes-1 {
        packet_data[it] = cast(u8) (it % 256);
    }
    return data_bytes + 2;
}

test_process_packet_function_validate_large :: (ctx: *void, id: u64, sequence: u16, packet_data: [] u8) -> bool {
    assert_true(packet_data.data != null);
    assert_true(packet_data.count >= 2);
    assert_true(packet_data.count <= TEST_MAX_PACKET_BYTES);

    data_bytes: u16 = 0;
    data_bytes |= cast(u16) packet_data[0];
    data_bytes |= (cast(u16) packet_data[1]) << 8;
    assert_equal(packet_data.count, cast(int) data_bytes + 2);
    for 2..data_bytes-1 {
        assert_equal(packet_data[it], cast(u8) (it % 256));
    }

    return true;
}

test_packets :: () {
    time := seconds_to_apollo(100);

    ctx: test_context_t;

    sender_config := reliable_config_t.{
        name = "sender",
        ctx = *ctx,
        id = 0,
        fragment_above = 500,
        transmit_packet_function = test_transmit_packet_function,
        process_packet_function = test_process_packet_function_validate
    };

    receiver_config := sender_config;
    receiver_config.name = "receiver";
    receiver_config.id = 1;

    ctx.sender = reliable_endpoint_create(*sender_config, time);
    ctx.receiver = reliable_endpoint_create(*receiver_config, time);

    delta_time := milliseconds_to_apollo(100);

    for 0..15 {
        {
            packet_data: [TEST_MAX_PACKET_BYTES] u8;
            sequence := reliable_endpoint_next_packet_sequence(ctx.sender);
            packet_bytes := generate_packet_data(sequence, packet_data);
            reliable_endpoint_send_packet(ctx.sender, .{ packet_bytes, packet_data.data });
        }

        {
            packet_data: [TEST_MAX_PACKET_BYTES] u8;
            sequence := reliable_endpoint_next_packet_sequence(ctx.sender);
            packet_bytes := generate_packet_data(sequence, packet_data);
            // NOTE(dlb): Changed from `ctx.sender` to `ctx.receiver`, see: https://github.com/mas-bandwidth/reliable/issues/31
            reliable_endpoint_send_packet(ctx.receiver, .{ packet_bytes, packet_data.data });
        }

        reliable_endpoint_update(ctx.sender, time);
        reliable_endpoint_update(ctx.receiver, time);

        reliable_endpoint_clear_acks(ctx.sender);
        reliable_endpoint_clear_acks(ctx.receiver);

        time += delta_time;
    }

    reliable_endpoint_destroy(ctx.sender);
    reliable_endpoint_destroy(ctx.receiver);
}

test_large_packets :: () {
    time := seconds_to_apollo(100);

    ctx: test_context_t;

    sender_config := reliable_config_t.{
        name = "sender",
        ctx = *ctx,
        id = 0,
        max_packet_size = TEST_MAX_PACKET_BYTES,
        fragment_above = TEST_MAX_PACKET_BYTES,
        transmit_packet_function = test_transmit_packet_function,
        process_packet_function = test_process_packet_function_validate_large
    };

    receiver_config := sender_config;
    receiver_config.name = "receiver";
    receiver_config.id = 1;

    ctx.sender = reliable_endpoint_create(*sender_config, time);
    ctx.receiver = reliable_endpoint_create(*receiver_config, time);

    {
        packet_data: [TEST_MAX_PACKET_BYTES] u8;
        packet_bytes := generate_packet_data_large(packet_data);
        assert(packet_bytes == TEST_MAX_PACKET_BYTES);
        reliable_endpoint_send_packet(ctx.sender, .{ packet_bytes, packet_data.data });
    }

    reliable_endpoint_update(ctx.sender, time);
    reliable_endpoint_update(ctx.receiver, time);

    reliable_endpoint_clear_acks(ctx.sender);
    reliable_endpoint_clear_acks(ctx.receiver);

    receiver_counters := reliable_endpoint_counters(ctx.receiver);
    assert(receiver_counters[RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_TOO_LARGE_TO_RECEIVE] == 0);
    assert(receiver_counters[RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_RECEIVED] == 1);

    reliable_endpoint_destroy(ctx.sender);
    reliable_endpoint_destroy(ctx.receiver);
}

test_sequence_buffer_rollover :: () {
    time := seconds_to_apollo(100);

    ctx: test_context_t;

    sender_config := reliable_config_t.{
        name = "sender",
        ctx = *ctx,
        id = 0,
        fragment_above = 500,
        transmit_packet_function = test_transmit_packet_function,
        process_packet_function = test_process_packet_function
    };

    receiver_config := sender_config;
    receiver_config.name = "receiver";
    receiver_config.id = 1;

    ctx.sender = reliable_endpoint_create(*sender_config, time);
    ctx.receiver = reliable_endpoint_create(*receiver_config, time);

    num_packets_sent: int = 0;
    for 0..32767 {
        packet_data: [16] u8;
        reliable_endpoint_send_packet(ctx.sender, packet_data);
        num_packets_sent += 1;
    }

    // NOTE(dlb): Not sure why we send one max-sized packet after the loop.. but ok.
    packet_data: [TEST_MAX_PACKET_BYTES] u8;
    reliable_endpoint_send_packet(ctx.sender, packet_data);
    num_packets_sent += 1;

    receiver_counters := reliable_endpoint_counters(ctx.receiver);

    assert_equal(cast(int) receiver_counters[RELIABLE_ENDPOINT_COUNTER_NUM_PACKETS_RECEIVED], num_packets_sent);
    assert_equal(receiver_counters[RELIABLE_ENDPOINT_COUNTER_NUM_FRAGMENTS_INVALID], cast(u64) 0);

    reliable_endpoint_destroy(ctx.sender);
    reliable_endpoint_destroy(ctx.receiver);
}

test_tracking_allocate_context_t :: struct {
    active_allocations: [1024] *void;
}

tracking_alloc_context: test_tracking_allocate_context_t;

test_tracking_allocate_function :: (pointer: *void) {
    ctx := *tracking_alloc_context;
    tracking_index := ctx.active_allocations.count;
    for ctx.active_allocations {
        if (it == null) {
            tracking_index = it_index;
            break;
        }
    }

    assert_true(tracking_index < ctx.active_allocations.count);
    ctx.active_allocations[tracking_index] = pointer;
}

test_tracking_free_function :: (pointer: *void) {
    ctx := *tracking_alloc_context;
    tracking_index := ctx.active_allocations.count;
    for ctx.active_allocations {
        if (it == pointer) {
            tracking_index = it_index;
            break;
        }
    }

    assert_true(tracking_index < ctx.active_allocations.count);
    ctx.active_allocations[tracking_index] = null;
}


test_fragment_cleanup :: () {
    tracking_allocator_proc :: (mode: Allocator_Mode, requested_size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
        default_allocator :: #import "Default_Allocator";
        ptr := default_allocator.allocator.proc(mode, requested_size, old_size, old_memory, allocator_data);

        if mode == {
            case .ALLOCATE;
                test_tracking_allocate_function(ptr);
            case .FREE;
                test_tracking_free_function(old_memory);
        }

        return ptr;
    }

    push_allocator(Allocator.{ tracking_allocator_proc, null });

    time := seconds_to_apollo(100);

    ctx: test_context_t;

    sender_config := reliable_config_t.{
        name = "sender",
        ctx = *ctx,
        id = 0,
        transmit_packet_function = test_transmit_packet_function,
        process_packet_function = test_process_packet_function
    };

    receiver_config := sender_config;
    receiver_config.name = "receiver";
    receiver_config.id = 1;
    receiver_config.fragment_reassembly_buffer_size = 4;

    ctx.sender = reliable_endpoint_create(*sender_config, time);
    ctx.receiver = reliable_endpoint_create(*receiver_config, time);

    delta_time := milliseconds_to_apollo(100);

    packet_sizes := int.[
        sender_config.fragment_size + sender_config.fragment_size/2,
        10,
        10,
        10,
        10,
    ];

    // Make sure we're sending more than receiver_config.fragment_reassembly_buffer_size packets, so the buffer wraps around.
    assert_true(packet_sizes.count > receiver_config.fragment_reassembly_buffer_size);

    for 0..packet_sizes.count-1 {
        // Only allow one packet per transmit, so that our fragmented packets are only partially
        // delivered.
        ctx.allow_packets = 1;
        {
            packet_data: [TEST_MAX_PACKET_BYTES] u8;
            packet_data_used: [] u8 = packet_data;
            packet_data_used.count = packet_sizes[it];

            sequence := reliable_endpoint_next_packet_sequence(ctx.sender);
            generate_packet_data_with_size(sequence, packet_data_used);
            reliable_endpoint_send_packet(ctx.sender, packet_data_used);
        }

        reliable_endpoint_update(ctx.sender, time);
        reliable_endpoint_update(ctx.receiver, time);

        reliable_endpoint_clear_acks(ctx.sender);
        reliable_endpoint_clear_acks(ctx.receiver);

        time += delta_time;
    }

    reliable_endpoint_destroy(ctx.sender);
    reliable_endpoint_destroy(ctx.receiver);

    // Make sure that there is no memory that hasn't been freed.
    for tracking_alloc_context.active_allocations {
        assert_null(it);
    }
}