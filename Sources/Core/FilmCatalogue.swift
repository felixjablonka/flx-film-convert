import Foundation

/// The film stocks FLX Film Convert offers: the negatives of FLX Film Lab's
/// packs that can still be bought new, so the menus stay short. Checked in
/// November 2026:
///
/// - Kodak: Ektar 100, Gold 200, Portra 160, 400 and 800 (and its pushes),
///   Ultramax 400, the four Vision3 stocks, Verita 200D (April 2026, by
///   request through Kodak's motion picture sales), T-Max 100, Tri-X 400.
/// - Ilford Delta 100 and 400, FP4 Plus, HP5 Plus, Pan F Plus and Ortho Plus.
///
/// Left out, as no longer made: Fujifilm C200 (now "Fujifilm 200", taken for
/// Kodak Gold), Pro 400H and Superia X-TRA 400 (Fujifilm confirmed both gone,
/// June 2025), Superia 1600, Superia Reala 100, Reala 500D, both Eternas,
/// Neopan 1600; Harman Phoenix 200 (succeeded by Phoenix II, a different
/// film, July 2025); Agfa APX 25, Optima II 100, Portrait XPS 160; Kodak Royal
/// Gold 100, Vericolor III 160, EXR 50D and 200T, 5251. A frame or roll set to
/// one of these keeps it, and the menu shows it.
enum FilmCatalogue {
    static let onSale: Set<String> = [
        "kodak_ektar_100", "kodak_gold_200", "kodak_ultramax_400",
        "kodak_portra_160", "kodak_portra_400", "kodak_portra_800",
        "kodak_portra_800_push1", "kodak_portra_800_push2",
        "kodak_vision3_50d", "kodak_vision3_200t", "kodak_vision3_250d", "kodak_vision3_500t",
        "kodak_verita_200d",
        "kodak_t_max_100", "kodak_tri_x_400", "kodak_tri_x_400_push2",
        "ilford_delta_100", "ilford_delta_400", "ilford_fp4_plus", "ilford_hp5_plus",
        "ilford_pan_f_plus", "ilford_ortho_plus",
    ]

    /// The menu's groups: the negatives on sale, and any of `kept` (the films
    /// the roll and the frame are set to) that are not.
    static func groups(including kept: [String?]) -> [(title: String, entries: [PackIndexEntry])] {
        let keep = Set(kept.compactMap { $0 })
        let entries = PackLibrary.shared.filmStocks.filter {
            $0.type != "positive" && (onSale.contains($0.stock) || keep.contains($0.stock))
        }
        return PackIndexEntry.groups(entries, films: true)
    }
}
