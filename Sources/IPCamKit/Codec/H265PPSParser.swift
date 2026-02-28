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

  if tilesEnabled {
    guard let numTileColumns = reader.readExpGolomb(),
      let numTileRows = reader.readExpGolomb()
    else {
      throw RTSPError.depacketizationError("PPS: can't read tile dimensions")
    }
    guard let uniformSpacing = reader.readBool() else {
      throw RTSPError.depacketizationError("PPS: can't read uniform_spacing_flag")
    }
    if !uniformSpacing {
      for _ in 0..<numTileColumns {
        _ = reader.readExpGolomb()  // column_width_minus1
      }
      for _ in 0..<numTileRows {
        _ = reader.readExpGolomb()  // row_height_minus1
      }
    }
    _ = reader.readBool()  // loop_filter_across_tiles_enabled_flag
  }

  _ = reader.readBool()  // pps_loop_filter_across_slices_enabled_flag
  if let deblockPresent = reader.readBool(), deblockPresent {
    _ = reader.readBool()  // deblocking_filter_override_enabled_flag
    if let disabled = reader.readBool(), !disabled {
      _ = reader.readSignedExpGolomb()  // pps_beta_offset_div2
      _ = reader.readSignedExpGolomb()  // pps_tc_offset_div2
    }
  }

  if let scalingListPresent = reader.readBool(), scalingListPresent {
    try skipH265ScalingListData(&reader)
  }
  _ = reader.readBool()  // lists_modification_present_flag
  _ = reader.readExpGolomb()  // log2_parallel_merge_level_minus2
  _ = reader.readBool()  // slice_segment_header_extension_present_flag

  if let extensionPresent = reader.readBool(), extensionPresent {
    let rangeExt = reader.readBool() ?? false
    let multilayerExt = reader.readBool() ?? false
    let ext3d = reader.readBool() ?? false
    let sccExt = reader.readBool() ?? false
    let ext4bits = reader.readBits(4) ?? 0
    if rangeExt {
      throw RTSPError.depacketizationError("pps_range_extension_flag unimplemented")
    }
    if multilayerExt {
      throw RTSPError.depacketizationError("pps_multilayer_extension_flag unimplemented")
    }
    if ext3d {
      throw RTSPError.depacketizationError("pps_3d_extension_flag unimplemented")
    }
    if sccExt {
      throw RTSPError.depacketizationError("pps_scc_extension_flag unimplemented")
    }
    if ext4bits != 0 {
      throw RTSPError.depacketizationError("pps_extension_4bits unimplemented")
    }
  }

  // finish_rbsp — tolerant

  return H265Pps(
    tilesEnabledFlag: tilesEnabled,
    entropyCodingSyncEnabledFlag: entropyCodingSyncEnabled)
}
