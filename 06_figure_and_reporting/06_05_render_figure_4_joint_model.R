#!/usr/bin/env Rscript

# Render Figure 4: the joint EffJ, early CJR, and later uptake model.

Sys.setenv(XDG_CACHE_HOME = "/private/tmp/journal_structure_font_cache")
dir.create(Sys.getenv("XDG_CACHE_HOME"), recursive = TRUE, showWarnings = FALSE)

suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(patchwork)
})

point_path <- "results/cumulative_handoff/joint_effj_cjr_handoff_results.csv"
draw_path <- "results/cumulative_handoff/joint_effj_cjr_handoff_bootstrap_draws.csv"
permutation_draw_path <- paste0(
  "results/direct_outcome_gap/",
  "journal_label_permutation_boundary_draws.csv"
)
permutation_summary_path <- paste0(
  "results/direct_outcome_gap/",
  "journal_label_permutation_boundary_summary.csv"
)
figure_dir <- "results/direct_outcome_gap/figures/main"
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)

font_family <- "Arial"
ink <- "#171717"
blue <- "#0072B2"
grey <- "#666666"
orange <- "#D55E00"
green <- "#009E73"
light_grey <- "#E2E2E2"

point <- fread(point_path)[universe == "full" & analytic_field == "pooled"]
draws <- fread(draw_path)[universe == "full"]
permutation_draws <- fread(permutation_draw_path)[
  universe == "full" &
    exposure == "openalex_log_eff_j" &
    shuffle_stratum == "openalex_topic_year"
]
permutation_summary <- fread(permutation_summary_path)[
  universe == "full" &
    exposure == "openalex_log_eff_j" &
    shuffle_stratum == "openalex_topic_year"
][1]

transform_percent <- function(x) {
  100 * (exp(x * log(2)) - 1)
}

effect_map <- data.table(
  effect = c(
    "total_log_effect_per_log_effj",
    "direct_log_effect_per_log_effj",
    "indirect_log_effect_per_log_effj"
  ),
  effect_label = c(
    "Total association",
    "Direct association\nholding early CJR constant",
    "Association through\nearly CJR"
  )
)

forest_data <- melt(
  point,
  measure.vars = effect_map$effect,
  variable.name = "effect",
  value.name = "log_estimate"
)[effect_map, on = "effect"]

bootstrap_intervals <- melt(
  draws,
  id.vars = "repetition",
  measure.vars = effect_map$effect,
  variable.name = "effect",
  value.name = "log_estimate"
)[
  , .(
    lower = transform_percent(quantile(log_estimate, 0.025)),
    upper = transform_percent(quantile(log_estimate, 0.975))
  ),
  by = effect
]

forest_data <- bootstrap_intervals[
  forest_data,
  on = "effect"
][
  , `:=`(
    estimate = transform_percent(log_estimate),
    effect_label = factor(effect_label, levels = rev(effect_map$effect_label))
  )
][
  , estimate_text := sprintf(
    "%.2f%% [%.2f, %.2f]", estimate, lower, upper
  )
][
  , log_text := paste0(
    "log coefficient ",
    sub("-", "\u2212", sprintf("%.6f", log_estimate), fixed = TRUE)
  )
][
  , `:=`(
    label_x = fifelse(
      effect == "indirect_log_effect_per_log_effj", estimate - 0.10, estimate
    ),
    label_hjust = fifelse(
      effect == "indirect_log_effect_per_log_effj", 1, 0.5
    )
  )
]

share_point <- 100 *
  point$indirect_log_effect_per_log_effj /
  point$total_log_effect_per_log_effj

share_draws <- 100 *
  draws$indirect_log_effect_per_log_effj /
  draws$total_log_effect_per_log_effj

share_median <- median(share_draws)
share_interval <- quantile(share_draws, c(0.025, 0.975))

p_path <- ggplot() +
  annotate(
    "rect",
    xmin = c(0.20, 2.68, 5.13), xmax = c(1.68, 4.16, 6.61),
    ymin = 1.30, ymax = 2.18,
    fill = c("#F2F2F2", "#EAF4FB", "#EAF7F1"),
    colour = grey, linewidth = 0.45
  ) +
  annotate(
    "text",
    x = c(0.94, 3.42, 5.87), y = 1.74,
    label = c(
      "Journal spread\n(EffJ)",
      "Early CJR\nyears 1-3",
      "Later citations\ncrossing journals\nyears 4-5"
    ),
    family = font_family, fontface = "bold", size = 3.45, lineheight = 0.95
  ) +
  annotate(
    "segment", x = 1.82, xend = 2.54, y = 1.74, yend = 1.74,
    arrow = arrow(length = unit(1.7, "mm"), type = "closed"),
    colour = blue, linewidth = 0.9
  ) +
  annotate(
    "segment", x = 4.30, xend = 4.99, y = 1.74, yend = 1.74,
    arrow = arrow(length = unit(1.7, "mm"), type = "closed"),
    colour = blue, linewidth = 0.9
  ) +
  annotate(
    "text", x = 2.18, y = 2.72,
    label = sprintf(
      "EffJ doubles\nearly CJR %.2f%%",
      point$early_cjr_change_percent_per_effj_doubling
    ),
    family = font_family, size = 3.10, colour = blue,
    fontface = "bold", lineheight = 0.95
  ) +
  annotate(
    "text", x = 4.64, y = 2.72,
    label = sprintf(
      "Early CJR +1 SD\nlater citations crossing journals\n+%.2f%%",
      point$later_cross_boundary_change_percent_per_one_sd_early_cjr
    ),
    family = font_family, size = 2.95, colour = blue,
    fontface = "bold", lineheight = 0.95
  ) +
  annotate(
    "curve", x = 1.05, xend = 5.78, y = 1.12, yend = 1.12,
    curvature = 0.17,
    arrow = arrow(length = unit(1.7, "mm"), type = "closed"),
    colour = grey, linewidth = 0.75, linetype = "dashed"
  ) +
  annotate(
    "label", x = 3.42, y = 0.18,
    label = sprintf(
      paste0(
        "EffJ doubles: %.2f%% later cross-journal citations\n",
        "holding early CJR constant"
      ),
      point$direct_change_percent_per_effj_doubling
    ),
    family = font_family, size = 3.10, colour = grey, lineheight = 0.95,
    fill = "white", linewidth = 0, label.padding = unit(0.8, "mm")
  ) +
  coord_cartesian(xlim = c(0.02, 6.80), ylim = c(0.02, 3.00), clip = "off") +
  theme_void(base_family = font_family) +
  theme(plot.margin = margin(4, 6, 4, 4))

p_forest <- ggplot(forest_data, aes(x = estimate, y = effect_label)) +
  geom_vline(xintercept = 0, colour = grey, linewidth = 0.45) +
  geom_errorbar(
    aes(xmin = lower, xmax = upper, colour = effect),
    orientation = "y", width = 0, linewidth = 0.75
  ) +
  geom_point(aes(colour = effect), size = 2.6) +
  geom_text(
    aes(
      x = label_x, label = estimate_text, hjust = label_hjust,
      colour = effect
    ),
    nudge_y = 0.23,
    family = font_family, size = 3.00
  ) +
  geom_text(
    aes(
      x = label_x, label = log_text, hjust = label_hjust,
      colour = effect
    ),
    nudge_y = -0.23,
    family = font_family, size = 2.80
  ) +
  scale_colour_manual(
    values = c(
      total_log_effect_per_log_effj = orange,
      direct_log_effect_per_log_effj = grey,
      indirect_log_effect_per_log_effj = blue
    ),
    guide = "none"
  ) +
  scale_x_continuous(limits = c(-3.35, 0.35), breaks = c(-3, -2, -1, 0)) +
  labs(
    x = "Change in later cross-journal citations\nwhen EffJ doubles (%)",
    y = NULL,
    title = "Full OpenAlex"
  ) +
  theme_classic(base_size = 10.8, base_family = font_family) +
  theme(
    axis.title = element_text(size = 10.8, colour = ink),
    axis.text = element_text(size = 9.8, colour = ink),
    axis.line = element_line(linewidth = 0.4, colour = ink),
    axis.ticks = element_line(linewidth = 0.4, colour = ink),
    plot.title = element_text(size = 11.7, face = "bold", hjust = 0),
    plot.margin = margin(3, 8, 4, 6)
  )

p_share <- ggplot() +
  annotate(
    "text", x = 0.50, y = 3.62,
    label = "Through early CJR",
    hjust = 0.5, family = font_family, fontface = "bold",
    size = 3.10, colour = blue
  ) +
  annotate(
    "text", x = 0.50, y = 3.12,
    label = sprintf("%.6f", point$indirect_log_effect_per_log_effj),
    hjust = 0.5, family = font_family, fontface = "bold",
    size = 4.20, colour = blue
  ) +
  annotate(
    "segment", x = 0.13, xend = 0.87, y = 2.80, yend = 2.80,
    linewidth = 0.65, colour = ink
  ) +
  annotate(
    "text", x = 0.50, y = 2.46,
    label = sprintf("%.6f", point$total_log_effect_per_log_effj),
    hjust = 0.5, family = font_family, fontface = "bold",
    size = 4.20, colour = orange
  ) +
  annotate(
    "text", x = 0.50, y = 2.02,
    label = "Total association",
    hjust = 0.5, family = font_family, fontface = "bold",
    size = 3.10, colour = orange
  ) +
  annotate(
    "text", x = 0.45, y = 1.42,
    label = "\u00d7 100 =",
    hjust = 1, family = font_family, fontface = "bold",
    size = 3.25, colour = ink
  ) +
  annotate(
    "text", x = 0.48, y = 1.42,
    label = sprintf("%.1f%%", share_point),
    hjust = 0, family = font_family, fontface = "bold",
    size = 4.65, colour = green
  ) +
  annotate(
    "text", x = 0.50, y = 0.57,
    label = paste0(
      "of the total EffJ association with\n",
      "later cross-journal citations\n",
      "is explained through early CJR"
    ),
    hjust = 0.5, family = font_family, fontface = "bold",
    size = 2.75, lineheight = 1.02, colour = ink
  ) +
  coord_cartesian(xlim = c(0, 1), ylim = c(0.20, 3.90), clip = "off") +
  theme_void(base_family = font_family) +
  theme(plot.margin = margin(3, 6, 4, 8))

bottom_panel <- (p_forest | p_share) +
  plot_layout(widths = c(1.34, 0.66))

toy_rows <- data.table(
  y = seq(5.95, 3.20, length.out = 6),
  paper = paste0("P", 1:6),
  cites = c("-", "P1", "-", "P3", "P2", "-"),
  observed_journal = c("A", "A", "B", "B", "C", "C"),
  permuted_journal = c("B", "A", "C", "A", "B", "C")
)
journal_colors <- c(A = orange, B = blue, C = green)

histogram <- hist(
  permutation_draws$same_journal_gap_pp,
  breaks = seq(-0.5, 10, by = 0.15),
  plot = FALSE,
  right = FALSE
)
histogram_data <- data.table(
  value_min = head(histogram$breaks, -1),
  value_max = tail(histogram$breaks, -1),
  count = histogram$counts
)[count > 0]

hist_x_left <- 11.05
hist_x_right <- 19.72
hist_y_bottom <- 1.55
hist_y_top <- 6.10
hist_y_max <- 200
map_hist_x <- function(value) {
  hist_x_left + (value / 10) * (hist_x_right - hist_x_left)
}
map_hist_y <- function(value) {
  hist_y_bottom + (value / hist_y_max) * (hist_y_top - hist_y_bottom)
}

histogram_data[
  , `:=`(
    plot_xmin = map_hist_x(value_min),
    plot_xmax = map_hist_x(value_max),
    plot_ymax = map_hist_y(count)
  )
]

observed_gap <- permutation_summary$actual_same_journal_gap_pp
null_mean <- 100 * permutation_summary$permutation_mean
null_low <- 100 * permutation_summary$permutation_q025
null_high <- 100 * permutation_summary$permutation_q975

p_permutation <- ggplot() +
  # Hypotheses occupy the full top row.
  annotate(
    "rect", xmin = 0.12, xmax = 10.00, ymin = 7.05, ymax = 8.18,
    fill = "#F3F3F3", colour = NA
  ) +
  annotate(
    "rect", xmin = 10.00, xmax = 19.88, ymin = 7.05, ymax = 8.18,
    fill = "#FFF2E8", colour = NA
  ) +
  annotate(
    "text", x = 0.42, y = 7.63, label = "H[0]", parse = TRUE,
    hjust = 0, family = font_family, fontface = "bold", size = 3.30,
    colour = grey
  ) +
  annotate(
    "text", x = 1.30, y = 7.63,
    label = paste0(
      "Journal labels are exchangeable within each topic-year.\n",
      "Actual labels add no citation sorting."
    ),
    hjust = 0, family = font_family, size = 2.24, colour = ink,
    lineheight = 0.94
  ) +
  annotate(
    "text", x = 10.32, y = 7.63, label = "H[A]", parse = TRUE,
    hjust = 0, family = font_family, fontface = "bold", size = 3.30,
    colour = orange
  ) +
  annotate(
    "text", x = 11.30, y = 7.63,
    label = paste0(
      "Actual journal membership produces stronger\n",
      "within-journal citation sorting."
    ),
    hjust = 0, family = font_family, size = 2.42, colour = ink,
    lineheight = 0.94
  ) +

  # Compact toy data: papers and citations stay fixed; only journals move.
  annotate("text", x = 1.90, y = 6.73, label = "Observed data",
           family = font_family, fontface = "bold", size = 2.75) +
  annotate("text", x = 7.80, y = 6.73, label = "One permutation",
           family = font_family, fontface = "bold", size = 2.75) +
  annotate("rect", xmin = 0.22, xmax = 3.58, ymin = 2.88, ymax = 6.47,
           fill = "white", colour = grey, linewidth = 0.38) +
  annotate("rect", xmin = 6.02, xmax = 9.38, ymin = 2.88, ymax = 6.47,
           fill = "white", colour = grey, linewidth = 0.38) +
  annotate("rect", xmin = c(0.22, 6.02), xmax = c(3.58, 9.38),
           ymin = 6.02, ymax = 6.47, fill = "#EFEFEF", colour = NA) +
  annotate("text", x = c(0.62, 1.80, 3.08, 6.42, 7.60, 8.88), y = 6.245,
           label = rep(c("Paper", "Cites", "Journal"), 2),
           family = font_family, fontface = "bold", size = 2.10) +
  geom_text(data = toy_rows, aes(x = 0.62, y = y, label = paper),
            family = font_family, size = 2.35) +
  geom_text(data = toy_rows, aes(x = 1.80, y = y, label = cites),
            family = font_family, size = 2.35) +
  geom_text(data = toy_rows,
            aes(x = 3.08, y = y, label = observed_journal,
                colour = observed_journal),
            family = font_family, fontface = "bold", size = 2.55) +
  geom_text(data = toy_rows, aes(x = 6.42, y = y, label = paper),
            family = font_family, size = 2.35) +
  geom_text(data = toy_rows, aes(x = 7.60, y = y, label = cites),
            family = font_family, size = 2.35) +
  geom_text(data = toy_rows,
            aes(x = 8.88, y = y, label = permuted_journal,
                colour = permuted_journal),
            family = font_family, fontface = "bold", size = 2.55) +
  annotate(
    "segment", x = 3.82, xend = 5.78, y = 4.60, yend = 4.60,
    arrow = arrow(length = unit(1.35, "mm"), type = "closed"),
    colour = ink, linewidth = 0.60
  ) +
  annotate(
    "text", x = 4.80, y = 5.22, label = "shuffle journal\nlabels only",
    family = font_family, fontface = "bold", size = 2.00, lineheight = 0.91
  ) +
  annotate(
    "text", x = 1.90, y = 2.38,
    label = "Papers, dates, and\ncitation ties stay fixed",
    family = font_family, size = 1.95, colour = grey, lineheight = 0.92
  ) +
  annotate(
    "text", x = 7.80, y = 2.38,
    label = "Journal counts stay\nA=2, B=2, C=2",
    family = font_family, size = 1.95, colour = grey, lineheight = 0.92
  ) +

  # Null histogram and the observed same-journal gap.
  annotate("segment", x = 10.12, xend = 10.12, y = 1.02, yend = 6.82,
           colour = light_grey, linewidth = 0.50) +
  annotate("text", x = 10.55, y = 6.72,
           label = "Null distribution: 1,000 exact-count permutations",
           hjust = 0, family = font_family, fontface = "bold", size = 2.75) +
  geom_segment(
    data = data.table(y_tick = c(0, 50, 100, 150, 200)),
    aes(x = hist_x_left, xend = hist_x_right,
        y = map_hist_y(y_tick), yend = map_hist_y(y_tick)),
    colour = "#ECECEC", linewidth = 0.32
  ) +
  geom_rect(
    data = histogram_data,
    aes(xmin = plot_xmin, xmax = plot_xmax,
        ymin = hist_y_bottom, ymax = plot_ymax),
    fill = "#AFAFAF", colour = "white", linewidth = 0.12
  ) +
  annotate("segment", x = hist_x_left, xend = hist_x_right,
           y = hist_y_bottom, yend = hist_y_bottom,
           colour = ink, linewidth = 0.40) +
  annotate("segment", x = hist_x_left, xend = hist_x_left,
           y = hist_y_bottom, yend = hist_y_top,
           colour = ink, linewidth = 0.40) +
  geom_segment(
    data = data.table(x_tick = c(0, 2, 4, 6, 8, 10)),
    aes(x = map_hist_x(x_tick), xend = map_hist_x(x_tick),
        y = hist_y_bottom, yend = hist_y_bottom - 0.10),
    colour = ink, linewidth = 0.36
  ) +
  geom_text(
    data = data.table(x_tick = c(0, 2, 4, 6, 8, 10)),
    aes(x = map_hist_x(x_tick), y = hist_y_bottom - 0.23, label = x_tick),
    family = font_family, size = 2.10
  ) +
  geom_text(
    data = data.table(y_tick = c(0, 50, 100, 150, 200)),
    aes(x = hist_x_left - 0.17, y = map_hist_y(y_tick), label = y_tick),
    hjust = 1, family = font_family, size = 1.95, colour = grey
  ) +
  annotate("segment", x = map_hist_x(null_mean), xend = map_hist_x(null_mean),
           y = hist_y_bottom, yend = 5.94,
           colour = blue, linewidth = 0.68, linetype = "dashed") +
  annotate("text", x = map_hist_x(null_mean) + 0.14, y = 5.98,
           label = sprintf("Null mean\n%.2f pp", null_mean),
           hjust = 0, family = font_family, fontface = "bold",
           size = 2.28, colour = blue, lineheight = 0.92) +
  annotate("segment", x = map_hist_x(observed_gap),
           xend = map_hist_x(observed_gap),
           y = hist_y_bottom, yend = 6.26,
           colour = orange, linewidth = 1.05) +
  annotate("text", x = map_hist_x(observed_gap) - 0.10, y = 6.33,
           label = sprintf("Observed %.2f pp", observed_gap),
           hjust = 1, family = font_family, fontface = "bold",
           size = 2.48, colour = orange) +
  annotate("text", x = 15.38, y = 0.83,
           label = "Within-minus-across citation probability (percentage points)",
           family = font_family, size = 2.30) +
  annotate("text", x = 10.48, y = 3.83, label = "Number of permutations",
           angle = 90, family = font_family, size = 2.18) +
  annotate("text", x = 14.62, y = 1.10,
           label = sprintf("95%% null range %.2f to %.2f pp", null_low, null_high),
           family = font_family, size = 2.18, colour = grey) +
  annotate("text", x = 18.86, y = 1.10, label = "p = .001",
           family = font_family, fontface = "bold", size = 2.30,
           colour = orange) +
  scale_colour_manual(values = journal_colors, guide = "none") +
  coord_cartesian(xlim = c(0.05, 19.95), ylim = c(0.72, 8.25), clip = "off") +
  theme_void(base_family = font_family) +
  theme(plot.margin = margin(0, 4, 0, 4))

figure <- p_path / bottom_panel / free(p_permutation) +
  plot_layout(heights = c(0.86, 0.86, 1.16)) +
  plot_annotation(
    tag_levels = "a",
    theme = theme(
      plot.tag = element_text(
        family = font_family, size = 9.2, face = "bold"
      ),
      plot.tag.position = c(0, 1)
    )
  )

width_in <- 190 / 25.4
height_in <- 185 / 25.4
stem <- file.path(figure_dir, "figure_4_joint_model")

ggsave(
  paste0(stem, ".pdf"), figure, device = cairo_pdf,
  width = width_in, height = height_in, units = "in", bg = "white"
)
ragg::agg_png(
  paste0(stem, ".png"), width = width_in, height = height_in,
  units = "in", res = 200, background = "white"
)
print(figure)
dev.off()
ragg::agg_tiff(
  paste0(stem, ".tiff"), width = width_in, height = height_in,
  units = "in", res = 300, compression = "lzw", background = "white"
)
print(figure)
dev.off()

cat("Rendered Figure 4 joint model.\n")
