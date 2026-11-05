// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/h265/nal.rs - H.265 PPS parser

import Foundation

/// Parsed H.265 Picture Parameter Set.
/// Only the fields needed for HEVCDecoderConfigurationRecord are retained.
struct H265Pps: Sendable {
  let tilesEnabledFlag: Bool
  let entropyCodingSyncEnabledFlag: Bool
}

/// Parse an H.265 PPS from RBSP bits (after NAL header has been stripped and RBSP decoded).
///
/// Reads only through `entropy_coding_sync_enabled_flag`, the last field kept.
/// The rest (tile layout, deblocking, scaling lists, extensions) is not
/// interpreted, so a PPS using syntax this parser doesn't implement, such as
/// `pps_range_extension`, is still accepted.
func parseH265PPS(_ rbsp: Data) throws -> H265Pps {
  var reader = BitReader(rbsp)

  _ = reader.readExpGolomb()  // pps_pic_parameter_set_id
  _ = reader.readExpGolomb()  // pps_seq_parameter_set_id
  _ = reader.readBool()  // dependent_slice_segments_enabled_flag
  _ = reader.readBool()  // output_flag_present_flag
  reader.skip(3)  // num_extra_slice_header_bits
  _ = reader.readBool()  // sign_data_hiding_enabled_flag
  _ = reader.readBool()  // cabac_init_present_flag
  _ = reader.readExpGolomb()  // num_ref_idx_l0_default_active_minus1
  _ = reader.readExpGolomb()  // num_ref_idx_l1_default_active_minus1
  _ = reader.readSignedExpGolomb()  // init_qp_minus26
  _ = reader.readBool()  // constrained_intra_pred_flag
  _ = reader.readBool()  // transform_skip_enabled_flag

  if let cuQpDeltaEnabled = reader.readBool(), cuQpDeltaEnabled {
    _ = reader.readExpGolomb()  // diff_cu_qp_delta_depth
  }
  _ = reader.readSignedExpGolomb()  // pps_cb_qp_offset
  _ = reader.readSignedExpGolomb()  // pps_cr_qp_offset
  _ = reader.readBool()  // pps_slice_chroma_qp_offsets_present_flag
  _ = reader.readBool()  // weighted_pred_flag
  _ = reader.readBool()  // weighted_bipred_flag
  _ = reader.readBool()  // transquant_bypass_enabled_flag

  guard let tilesEnabled = reader.readBool(),
    let entropyCodingSyncEnabled = reader.readBool()
  else {
    throw RTSPError.depacketizationError("PPS: can't read tiles/entropy flags")
  }

  return H265Pps(
    tilesEnabledFlag: tilesEnabled,
    entropyCodingSyncEnabledFlag: entropyCodingSyncEnabled)
}
