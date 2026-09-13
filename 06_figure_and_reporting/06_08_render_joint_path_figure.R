#!/usr/bin/env Rscript

# Render the joint EffJ, early CJR, and later cross-journal uptake result.

Sys.setenv(XDG_CACHE_HOME = "/private/tmp/journal_structure_font_cache")
dir.create(Sys.getenv("XDG_CACHE_HOME"), recursive = TRUE, showWarnings = FALSE)

suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(patchwork)
})

point_path <- "results/cumulative_handoff/joint_effj_cjr_handoff_results.csv"
draw_path <-
  "results/cumulative_handoff/joint_effj_cjr_handoff_bootstrap_draws.csv"
figure_dir <- "results/cumulative_handoff/figures"
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)

font_family <- "Arial"
ink <- "#171717"
blue <- "#0072B2"
orange <- "#D55E00"
grey <- "#666666"

points <- fread(point_path)[analytic_field == "pooled"]
draws <- fread(draw_path)

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
    "Direct association\ncontrolling early CJR",
    "Association through\nearly CJR"
  )
)

forest_data <- melt(
  points,
  id.vars = c("universe", "analytic_field"),
  measure.vars = effect_map$effect,
  variable.name = "effect",
  value.name = "log_estimate"
)[effect_map, on = "effect"]

bootstrap_intervals <- melt(
  draws,
  id.vars = c("universe", "repetition"),
  measure.vars = effect_map$effect,
  variable.name = "effect",
  value.name = "log_estimate"
)[
  , .(
    lower = transform_percent(quantile(log_estimate, 0.025)),
    upper = transform_percent(quantile(log_estimate, 0.975))
  ),
  by = .(universe, effect)
]

forest_data <- bootstrap_intervals[
  forest_data,
  on = .(universe, effect)
][
  , `:=`(
    estimate = transform_percent(log_estimate),
    universe_label = fifelse(
      universe == "full", "Full OpenAlex", "SCImago-matched"
    ),
    effect_label = factor(
      effect_label,
      levels = rev(effect_map$effect_label)
    )
  )
][
  , estimate_text := sprintf("%.2f [%.2f, %.2f]", estimate, lower, upper)
]

full_point <- points[universe == "full"]

p_path <- ggplot() +
  annotate(
    "rect", xmin = c(0.25, 2.48, 5.05), xmax = c(1.55, 3.78, 6.35),
    ymin = 1.28, ymax = 2.15,
    fill = c("#F2F2F2", "#EAF4FB", "#EAF7F1"), colour = grey,
    linewidth = 0.45
  ) +
  annotate(
    "text", x = c(0.90, 3.13, 5.70), y = 1.72,
    label = c("More journals\nserve the subfield", "Lower early CJR",
              "Fewer later citations\ncross journals"),
    family = font_family, fontface = "bold", size = 3.55, lineheight = 0.95
  ) +
  annotate(
    "segment", x = 1.68, xend = 2.35, y = 1.72, yend = 1.72,
    arrow = arrow(length = unit(1.7, "mm"), type = "closed"),
    colour = blue, linewidth = 0.9
  ) +
  annotate(
    "segment", x = 3.91, xend = 4.92, y = 1.72, yend = 1.72,
    arrow = arrow(length = unit(1.7, "mm"), type = "closed"),
    colour = blue, linewidth = 0.9
  ) +
  annotate(
    "text", x = 2.02, y = 2.43,
    label = sprintf(
      "EffJ doubles: %.2f%%", full_point$early_cjr_change_percent_per_effj_doubling
    ),
    family = font_family, size = 3.20, colour = blue, fontface = "bold"
  ) +
  annotate(
    "text", x = 4.42, y = 2.43,
    label = sprintf(
      "Early CJR +1 SD: +%.2f%%",
      full_point$later_cross_boundary_change_percent_per_one_sd_early_cjr
    ),
    family = font_family, size = 3.20, colour = blue, fontface = "bold"
  ) +
  annotate(
    "curve", x = 1.15, xend = 5.42, y = 1.12, yend = 1.12,
    curvature = 0.22,
    arrow = arrow(length = unit(1.7, "mm"), type = "closed"),
    colour = grey, linewidth = 0.75, linetype = "dashed"
  ) +
  annotate(
    "text", x = 3.30, y = 0.43,
    label = sprintf(
      "Direct association after controlling early CJR: %.2f%%",
      full_point$direct_change_percent_per_effj_doubling
    ),
    family = font_family, size = 3.20, colour = grey
  ) +
  annotate(
    "text", x = 3.30, y = 2.95, label = "Joint pathway",
    family = font_family, fontface = "bold", size = 4.15
  ) +
  coord_cartesian(xlim = c(0.05, 6.55), ylim = c(0.42, 3.12), clip = "off") +
  theme_void(base_family = font_family) +
  theme(plot.margin = margin(3, 4, 3, 4))

p_forest <- ggplot(
  forest_data,
  aes(x = estimate, y = effect_label)
) +
  geom_vline(xintercept = 0, colour = grey, linewidth = 0.45) +
  geom_errorbar(
    aes(xmin = lower, xmax = upper), orientation = "y", width = 0,
    linewidth = 0.75, colour = blue
  ) +
  geom_point(size = 2.6, colour = blue) +
  geom_text(
    aes(label = estimate_text), nudge_y = 0.20,
    family = font_family, size = 3.05, colour = ink
  ) +
  facet_wrap(~universe_label, nrow = 1) +
  scale_x_continuous(
    limits = c(-3.2, 0.35), breaks = c(-3, -2, -1, 0)
  ) +
  labs(
    x = "Percent change in later citations crossing journals when EffJ doubles",
    y = NULL,
    title = "Total, direct, and through early CJR"
  ) +
  theme_classic(base_size = 11.7, base_family = font_family) +
  theme(
    axis.title = element_text(size = 11.7, colour = ink),
    axis.text = element_text(size = 10.6, colour = ink),
    axis.line = element_line(linewidth = 0.4, colour = ink),
    axis.ticks = element_line(linewidth = 0.4, colour = ink),
    strip.background = element_blank(),
    strip.text = element_text(size = 11.1, face = "bold", hjust = 0),
    plot.title = element_text(size = 12.5, face = "bold", hjust = 0),
    plot.margin = margin(3, 6, 4, 6)
  )

figure <- p_path / p_forest +
  plot_layout(heights = c(0.84, 1.15)) +
  plot_annotation(
    tag_levels = "a",
    theme = theme(
      plot.tag = element_text(
        family = font_family, size = 10.1, face = "bold"
      ),
      plot.tag.position = c(0, 1)
    )
  )

width_in <- 183 / 25.4
height_in <- 150 / 25.4
stem <- file.path(figure_dir, "figure_joint_effj_cjr_handoff")

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

cat("Rendered joint pathway figure.\n")
