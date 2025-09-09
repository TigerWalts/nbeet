import gleam/bit_array
import gleam/int
import gleam/result

//  Case    utf8                                                                        mutf8
//  ------------------------------------------------------------------------------------------------------------------------------------------
//  Null    00000000                            <------------special case-------------> 11000000 10000000
//  1-byte  0yyyzzzz                            <----------------same-----------------> 0yyyzzzz
//  2-byte  110xxxyy 10yyzzzz                   <----------------same-----------------> 110xxxyy 10yyzzzz
//  3-byte  1110wwww 10xxxxyy 10yyzzzz          <----------------same-----------------> 1110wwww 10xxxxyy 10yyzzzz
//  4-byte  11110vvv 10vvwwww 10xxxxyy 10yyzzzz <-v is decremented and cast to 4 bits-> 11101101 1010vvvv 10wwwwxx 11101101 1011xxyy 10yyzzzz

// Encode

pub fn bitarray_from_string(value: String) -> Result(BitArray, String) {
  bitarray_from_string_impl(value |> bit_array.from_string, <<>>)
}

fn bitarray_from_string_impl(
  from: BitArray,
  into: BitArray,
) -> Result(BitArray, String) {
  case split_at_first_multibyte(from, 0) {
    #(<<>>, rest) ->
      case rest {
        // Finished
        <<>> -> Ok(into)
        // Null
        <<0, rest:bits>> ->
          bitarray_from_string_impl(rest, <<into:bits, 0xC0, 0x80>>)
        // 2-byte
        <<0b110:size(3), cont:bits-size(13), rest:bits>> ->
          bitarray_from_string_impl(rest, <<
            into:bits,
            0b110:size(3),
            cont:bits-size(13),
          >>)
        // 3-byte
        <<0b1110:size(4), cont:bits-size(20), rest:bits>> ->
          bitarray_from_string_impl(rest, <<
            into:bits,
            0b1110:size(4),
            cont:bits-size(20),
          >>)
        // 4-byte -> 6-byte
        <<
          0b11110:size(5),
          t:bits-size(3),
          0b10:size(2),
          u:bits-size(2),
          w:bits-size(4),
          0b10:size(2),
          x:bits-size(2),
          y:bits-size(4),
          0b10:size(2),
          z:bits-size(6),
          rest:bits,
        >> -> {
          let assert <<v>> = <<0b000:size(3), t:bits-size(3), u:bits-size(2)>>
          let v = v - 1
          bitarray_from_string_impl(rest, <<
            into:bits,
            0xed,
            0xa:size(4),
            v:size(4),
            0b10:size(2),
            w:bits-size(4),
            x:bits-size(2),
            0xed,
            0xb:size(4),
            y:bits-size(4),
            0b10:size(2),
            z:bits-size(6),
          >>)
        }
        // Invalid
        _ -> {
          let assert <<a, _rest:bits>> = rest
          let assert Ok(bits) = int.to_base_string(a, 2)
          Error(
            "Unexpected bytes while encoding string to mutf8, expected the start of a multi-byte character, next byte is: 0x"
            <> bits,
          )
        }
      }

    #(mono_bytes, <<>>) -> Ok(<<into:bits, mono_bytes:bits>>)

    #(mono_bytes, rest) ->
      bitarray_from_string_impl(rest, <<into:bits, mono_bytes:bits>>)
  }
}

// Decode

pub fn string_from_bitarray(data: BitArray) -> Result(String, String) {
  string_from_bitarray_impl(data, <<>>)
}

fn string_from_bitarray_impl(
  from: BitArray,
  into: BitArray,
) -> Result(String, String) {
  case split_at_first_multibyte(from, 0) {
    #(<<>>, rest) ->
      case rest {
        // Finished
        <<>> ->
          into
          |> bit_array.to_string
          |> result.map_error(fn(_) { "Failed to decode from mutf8 to utf8" })
        // Null
        <<0xC0, 0x80, rest:bits>> ->
          string_from_bitarray_impl(rest, <<into:bits, 0>>)
        // 2-byte
        <<0b110:size(3), cont:bits-size(13), rest:bits>> ->
          string_from_bitarray_impl(rest, <<
            into:bits,
            0b110:size(3),
            cont:bits-size(13),
          >>)
        // 6-byte into 4-byte
        <<
          0xed,
          0xa:size(4),
          v:size(4),
          0b10:size(2),
          w:bits-size(4),
          x:bits-size(2),
          0xed,
          0xb:size(4),
          y:bits-size(4),
          0b10:size(2),
          z:bits-size(6),
          rest:bits,
        >> -> {
          let v = v + 1
          let assert <<t:bits-size(3), u:bits-size(2)>> = <<v:size(5)>>
          string_from_bitarray_impl(rest, <<
            into:bits,
            0b11110:size(5),
            t:bits-size(3),
            0b10:size(2),
            u:bits-size(2),
            w:bits-size(4),
            0b10:size(2),
            x:bits-size(2),
            y:bits-size(4),
            0b10:size(2),
            z:bits-size(6),
          >>)
        }
        // 3-byte
        <<0b1110:size(4), cont:bits-size(20), rest:bits>> ->
          string_from_bitarray_impl(rest, <<
            into:bits,
            0b1110:size(4),
            cont:bits-size(20),
          >>)
        // Invalid
        _ -> {
          let assert <<a, _rest:bits>> = rest
          let assert Ok(bits) = int.to_base_string(a, 2)
          Error(
            "Unexpected bytes while encoding string to mutf8, expected the start of a multi-byte character, next byte is: 0x"
            <> bits,
          )
        }
      }

    //Finished
    #(mono_bytes, <<>>) ->
      <<into:bits, mono_bytes:bits>>
      |> bit_array.to_string
      |> result.map_error(fn(_) { "Failed to decode from mutf8 to utf8" })

    #(mono_bytes, rest) ->
      string_from_bitarray_impl(rest, <<into:bits, mono_bytes:bits>>)
  }
}

fn split_at_first_multibyte(from: BitArray, at: Int) -> #(BitArray, BitArray) {
  case from {
    <<before:bits-size(at)>> -> #(before, <<>>)

    <<before:bits-size(at), 0, rest:bits>> -> #(before, <<0, rest:bits>>)

    <<before:bits-size(at), 1:size(1), rest:bits>> -> #(before, <<
      1:size(1),
      rest:bits,
    >>)

    <<_before:bits-size(at), 0:size(1), _rest:bits>> ->
      split_at_first_multibyte(from, at + 8)

    _ -> panic as "Unreachable"
  }
}
