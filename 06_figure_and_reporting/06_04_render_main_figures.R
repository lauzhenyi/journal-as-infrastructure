#!/usr/bin/env Rscript

# Render manuscript Figures 1-3.

Sys.setenv(XDG_CACHE_HOME = "/private/tmp/journal_structure_font_cache")
dir.create(Sys.getenv("XDG_CACHE_HOME"), recursive = TRUE, showWarnings = FALSE)

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(ggplot2)
  library(ggrepel)
  library(patchwork)
  library(readr)
  library(stringr)
  library(tidyr)
})

set.seed(20260830)

result_dir <- "results/direct_outcome_gap"
data_dir <- file.path(result_dir, "main_figure_data")
figure_dir <- file.path(result_dir, "figures", "main")
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)

font_family <- "Arial"
ink <- "#171717"
grey <- "#B9B9B9"
dark_grey <- "#666666"
light_grey <- "#E2E2E2"
blue <- "#0072B2"
orange <- "#D55E00"
green <- "#009E73"

field_order <- c(
  "Biology", "Chemistry", "Geology", "Materials science", "Medicine", "Physics"
)
field_colors <- c(
  "Biology" = "#009E73",
  "Chemistry" = "#E69F00",
  "Geology" = "#8C6D31",
  "Materials science" = "#CC79A7",
  "Medicine" = "#0072B2",
  "Physics" = "#6A51A3"
)

clean_field <- function(x) {
  recode(
    x,
    biology = "Biology",
    chemistry = "Chemistry",
    geology = "Geology",
    materials_science = "Materials science",
    medicine = "Medicine",
    physics = "Physics",
    pooled = "Pooled"
  )
}

percent_ci_from_log <- function(effect, standard_error) {
  log_effect <- log1p(effect / 100)
  tibble(
    ci_low_percent = 100 * (exp(log_effect - 1.96 * standard_error) - 1),
    ci_high_percent = 100 * (exp(log_effect + 1.96 * standard_error) - 1)
  )
}

theme_main <- function(base_size = 9.75) {
  theme_classic(base_size = base_size, base_family = font_family) +
    theme(
      axis.title = element_text(size = 9.75, colour = ink, face = "plain"),
      axis.title.y = element_text(margin = margin(r = 5)),
      axis.text = element_text(size = 8.85, colour = ink),
      axis.line = element_line(linewidth = 0.35, colour = ink),
      axis.ticks = element_line(linewidth = 0.35, colour = ink),
      axis.ticks.length = unit(1.4, "mm"),
      strip.background = element_blank(),
      strip.text = element_text(size = 9.25, face = "bold", hjust = 0),
      legend.title = element_blank(),
      legend.text = element_text(size = 8.85),
      plot.title = element_text(size = 10.4, face = "bold", hjust = 0),
      plot.subtitle = element_blank(),
      plot.margin = margin(4, 5, 4, 5)
    )
}

tag_theme <- theme(
  plot.tag = element_text(family = font_family, size = 8.45, face = "bold"),
  plot.tag.position = c(0, 1)
)

tag_theme_figure2 <- theme(
  plot.tag = element_text(
    family = font_family, size = 8.45, face = "bold", hjust = 1
  ),
  plot.tag.position = c(0.018, 1)
)

save_main <- function(plot, stem, height_mm, width_mm = 183) {
  width_in <- width_mm / 25.4
  height_in <- height_mm / 25.4
  ggsave(
    file.path(figure_dir, paste0(stem, ".pdf")),
    plot,
    device = cairo_pdf,
    width = width_in,
    height = height_in,
    units = "in",
    bg = "white"
  )
  ragg::agg_tiff(
    file.path(figure_dir, paste0(stem, ".tiff")),
    width = width_in,
    height = height_in,
    units = "in",
    res = 300,
    compression = "lzw",
    background = "white"
  )
  print(plot)
  dev.off()
  ragg::agg_png(
    file.path(figure_dir, paste0(stem, ".png")),
    width = width_in,
    height = height_in,
    units = "in",
    res = 200,
    background = "white"
  )
  print(plot)
  dev.off()
}

topic_year <- read_csv(
  file.path(data_dir, "topic_year_descriptives.csv"),
  show_col_types = FALSE
) %>%
  mutate(
    field = factor(clean_field(analytic_field), levels = field_order),
    connection_ratio = exp(log_cross_within_rate_ratio)
  )

topic_medians <- read_csv(
  file.path(data_dir, "topic_effj_medians.csv"),
  show_col_types = FALSE
) %>%
  mutate(
    field = factor(clean_field(analytic_field), levels = field_order),
    log2_median_eff_j = log2(median_eff_j)
  )

# Figure 1a: population, focal-paper inclusion, exposure, and outcome.
p1a <- ggplot() +
  # Population flow.
  annotate("text", x = 0.25, y = 8.95, label = "Study population",
           hjust = 0, family = font_family, fontface = "bold", size = 3.35) +
  annotate("text", x = 0.35, y = c(8.35, 7.50, 6.65),
           label = c("9,638,405", "8,417,036", "4,469,511"),
           hjust = 0, family = font_family, fontface = "bold", size = 4.10) +
  annotate("text", x = 2.65, y = c(8.35, 7.50, 6.65),
           label = c(
             "Starting sample: six fields, 2015-2023",
             "Author + institution identified",
             "Main analysis: 2-20 follow-on papers"
           ), hjust = 0, family = font_family, size = 2.20) +
  annotate("segment", x = c(1.28, 1.28), xend = c(1.28, 1.28),
           y = c(8.05, 7.20), yend = c(7.78, 6.93),
           arrow = arrow(length = unit(1.5, "mm"), type = "closed"),
           colour = ink, linewidth = 0.55) +

  # Compact included and excluded examples beside the final count.
  annotate("segment", x = 7.45, xend = 7.45, y = 6.45, yend = 8.95,
           colour = light_grey, linewidth = 0.45) +
  annotate("text", x = 7.75, y = 8.88,
           label = "A follow-on paper cites P0\nwithin three years",
           hjust = 0, family = font_family, fontface = "bold", size = 2.55,
           lineheight = 0.92) +
  annotate("segment", x = 7.82, xend = 9.48, y = 8.02, yend = 8.02,
           colour = ink, linewidth = 0.40) +
  annotate("point", x = 7.92, y = 8.02, shape = 22, size = 3.1,
           fill = ink, colour = ink) +
  annotate("text", x = 7.92, y = 8.02, label = "P0",
           family = font_family, fontface = "bold", size = 1.75, colour = "white") +
  annotate("point", x = c(8.45, 8.93, 9.40), y = 8.02,
           shape = 16, size = 1.55, colour = blue) +
  annotate("segment", x = c(8.38, 8.86, 9.33), xend = 8.03,
           y = 8.02, yend = 8.02,
           arrow = arrow(length = unit(0.8, "mm"), type = "closed"),
           colour = blue, linewidth = 0.45) +
  annotate("text", x = 9.75, y = 8.02,
           label = "Included\n3 follow-on papers", hjust = 0,
           family = font_family, fontface = "bold", size = 2.25,
           lineheight = 0.92, colour = blue) +
  annotate("segment", x = 7.82, xend = 9.48, y = 6.92, yend = 6.92,
           colour = ink, linewidth = 0.40) +
  annotate("point", x = 7.92, y = 6.92, shape = 22, size = 3.1,
           fill = ink, colour = ink) +
  annotate("text", x = 7.92, y = 6.92, label = "P0",
           family = font_family, fontface = "bold", size = 1.75, colour = "white") +
  annotate("point", x = c(8.45, 8.93, 9.40), y = 6.92,
           shape = 16, size = 1.45, colour = grey) +
  annotate("text", x = 9.75, y = 6.92,
           label = "Not included\n0 follow-on papers", hjust = 0,
           family = font_family, fontface = "bold", size = 2.25,
           lineheight = 0.92, colour = dark_grey) +
  annotate("text", x = c(7.82, 9.48), y = c(6.53, 6.53),
           label = c("P0", "3 years"), family = font_family,
           size = 1.85, colour = dark_grey) +
  annotate("segment", x = 0.25, xend = 11.80, y = 6.15, yend = 6.15,
           colour = light_grey, linewidth = 0.45) +

  # Independent variable: EffJ.
  annotate("text", x = 0.25, y = 5.78, label = "Independent variable",
           hjust = 0, family = font_family, fontface = "bold", size = 3.05) +
  annotate("text", x = 0.25, y = 5.28, label = "EffJ",
           hjust = 0, family = font_family, fontface = "bold", size = 3.75,
           colour = green) +
  annotate("text", x = 1.20, y = 5.28,
           label = "Number of similarly sized journals\nserving the subfield in that year",
           hjust = 0, family = font_family, size = 2.50, lineheight = 0.95) +
  annotate("text", x = 1.45, y = 4.30, label = "One dominant\njournal",
           family = font_family, size = 2.20, lineheight = 0.92) +
  annotate("rect", xmin = c(0.55, 1.10, 1.65, 2.20),
           xmax = c(0.88, 1.43, 1.98, 2.53), ymin = 2.20,
           ymax = c(3.88, 2.55, 2.42, 2.34),
           fill = c(green, grey, grey, grey), colour = NA) +
  annotate("text", x = 1.54, y = 1.82, label = "EffJ near 1",
           family = font_family, size = 2.35) +
  annotate("text", x = 4.15, y = 4.30, label = "Four similar\njournals",
           family = font_family, size = 2.20, lineheight = 0.92) +
  annotate("rect", xmin = c(3.25, 3.80, 4.35, 4.90),
           xmax = c(3.58, 4.13, 4.68, 5.23), ymin = 2.20,
           ymax = c(3.20, 3.13, 3.25, 3.18),
           fill = green, colour = NA) +
  annotate("text", x = 4.24, y = 1.82, label = "EffJ near 4",
           family = font_family, size = 2.35) +
  annotate("text", x = 2.90, y = 1.20,
           label = "Journal publication shares within one subfield-year",
           family = font_family, size = 2.35, colour = dark_grey) +

  # Dependent variable: across- relative to within-journal citation probability.
  annotate("segment", x = 5.78, xend = 5.78, y = 0.72, yend = 5.86,
           colour = light_grey, linewidth = 0.45) +
  annotate("text", x = 6.10, y = 5.78, label = "Dependent variable",
           hjust = 0, family = font_family, fontface = "bold", size = 3.05) +
  annotate("text", x = 6.10, y = 5.28,
           label = "Cross-journal connection ratio (CJR)",
           hjust = 0, family = font_family, fontface = "bold", size = 3.05) +
  annotate("text", x = 6.10, y = 4.82,
           label = "across-journal citation rate\n÷ within-journal citation rate",
           hjust = 0, family = font_family, size = 2.45, lineheight = 0.92) +
  annotate("text", x = 7.45, y = 4.05, label = "Within journal",
           family = font_family, fontface = "bold", size = 2.55, colour = orange) +
  annotate("text", x = 6.80, y = 3.42, label = "Journal A", hjust = 1,
           family = font_family, size = 2.20) +
  annotate("segment", x = 7.00, xend = 8.85, y = 3.42, yend = 3.42,
           colour = light_grey, linewidth = 0.95) +
  annotate("point", x = c(7.35, 8.43), y = 3.42, shape = 22, size = 3.25,
           fill = ink, colour = ink) +
  annotate("segment", x = 8.31, xend = 7.47, y = 3.42, yend = 3.42,
           arrow = arrow(length = unit(1.0, "mm"), type = "closed"),
           colour = orange, linewidth = 0.70) +
  annotate("text", x = 7.88, y = 2.50,
           label = "same-journal pairs",
           family = font_family, size = 2.25) +
  annotate("text", x = 10.42, y = 4.05, label = "Across journals",
           family = font_family, fontface = "bold", size = 2.55, colour = blue) +
  annotate("text", x = 9.72, y = c(3.62, 2.84),
           label = c("Journal A", "Journal B"), hjust = 1,
           family = font_family, size = 2.20) +
  annotate("segment", x = 9.92, xend = 11.75, y = c(3.62, 2.84),
           yend = c(3.62, 2.84), colour = light_grey, linewidth = 0.95) +
  annotate("point", x = c(10.33, 11.35), y = c(3.62, 2.84),
           shape = 22, size = 3.25, fill = ink, colour = ink) +
  annotate("segment", x = 11.24, xend = 10.45, y = 2.92, yend = 3.54,
           arrow = arrow(length = unit(1.0, "mm"), type = "closed"),
           colour = blue, linewidth = 0.70) +
  annotate("text", x = 10.55, y = 2.15,
           label = "different-journal pairs",
           family = font_family, size = 2.25) +
  coord_cartesian(xlim = c(0.10, 11.95), ylim = c(0.65, 9.10), clip = "off") +
  theme_void(base_family = font_family) +
  theme(plot.margin = margin(2, 4, 2, 0))

# Figure 1a: full-width sample construction and follow-on-paper definition.
p1a_sample <- ggplot() +
  annotate("text", x = 0.35, y = 5.72, label = "Study population",
           hjust = 0, family = font_family, fontface = "bold", size = 3.45) +
  annotate("text", x = c(2.10, 7.90, 13.90), y = 5.12,
           label = c("9,638,405", "8,417,036", "4,469,511"),
           family = font_family, fontface = "bold", size = 4.20) +
  annotate("text", x = c(2.10, 7.90, 13.90), y = 4.52,
           label = c(
             "Journal articles\nsix fields, 2015-2023",
             "Author + institution\nidentified",
             "Papers with 2-20 follow-on papers within 3 years\nare included in the analysis"
           ), family = font_family, size = 2.60, lineheight = 0.93) +
  annotate("segment", x = c(3.75, 9.55), xend = c(5.65, 11.60),
           y = 5.10, yend = 5.10,
           arrow = arrow(length = unit(1.5, "mm"), type = "closed"),
           colour = ink, linewidth = 0.55) +
  annotate("segment", x = 0.35, xend = 19.65, y = 3.95, yend = 3.95,
           colour = light_grey, linewidth = 0.45) +
  annotate("text", x = 0.35, y = 3.65,
           label = "A follow-on paper is a later paper that directly cites P0 within 3 years",
           hjust = 0, family = font_family, fontface = "bold", size = 3.15) +

  # Included case with citation arrows and a separate time axis.
  annotate("text", x = 5.00, y = 3.15, label = "Included",
           family = font_family, fontface = "bold", size = 3.00, colour = blue) +
  annotate("point", x = 1.80, y = 2.18, shape = 22, size = 3.7,
           fill = ink, colour = ink) +
  annotate("text", x = 1.80, y = 2.18, label = "P0",
           family = font_family, fontface = "bold", size = 2.05, colour = "white") +
  annotate("point", x = c(4.00, 6.00, 8.00), y = c(2.46, 1.93, 2.38),
           shape = 16, size = 1.95, colour = blue) +
  annotate("segment", x = c(3.91, 5.91, 7.91),
           y = c(2.45, 1.94, 2.37), xend = 1.92, yend = 2.18,
           arrow = arrow(length = unit(1.0, "mm"), type = "closed"),
           colour = blue, linewidth = 0.58) +
  annotate("text", x = 5.00, y = 1.45,
           label = "3 follow-on papers; P0 is included",
           family = font_family, size = 2.45) +
  annotate("segment", x = 1.80, xend = 8.40, y = 0.82, yend = 0.82,
           colour = ink, linewidth = 0.42) +
  annotate("segment", x = c(1.80, 4.00, 6.20, 8.40),
           xend = c(1.80, 4.00, 6.20, 8.40), y = 0.73, yend = 0.91,
           colour = ink, linewidth = 0.38) +
  annotate("text", x = c(1.80, 4.00, 6.20, 8.40), y = 0.48,
           label = c("P0", "year 1", "year 2", "year 3"),
           family = font_family, size = 2.20) +

  # Excluded case with no citation arrows and a separate time axis.
  annotate("segment", x = 10.00, xend = 10.00, y = 0.38, yend = 3.28,
           colour = light_grey, linewidth = 0.45) +
  annotate("text", x = 15.00, y = 3.15, label = "Not included",
           family = font_family, fontface = "bold", size = 3.00, colour = dark_grey) +
  annotate("point", x = 11.80, y = 2.18, shape = 22, size = 3.7,
           fill = ink, colour = ink) +
  annotate("text", x = 11.80, y = 2.18, label = "P0",
           family = font_family, fontface = "bold", size = 2.05, colour = "white") +
  annotate("point", x = c(14.00, 16.00, 18.00), y = c(2.46, 1.93, 2.38),
           shape = 16, size = 1.90, colour = grey) +
  annotate("text", x = 15.00, y = 1.45,
           label = "0 follow-on papers; P0 is not included",
           family = font_family, size = 2.45) +
  annotate("segment", x = 11.80, xend = 18.40, y = 0.82, yend = 0.82,
           colour = ink, linewidth = 0.42) +
  annotate("segment", x = c(11.80, 14.00, 16.20, 18.40),
           xend = c(11.80, 14.00, 16.20, 18.40), y = 0.73, yend = 0.91,
           colour = ink, linewidth = 0.38) +
  annotate("text", x = c(11.80, 14.00, 16.20, 18.40), y = 0.48,
           label = c("P0", "year 1", "year 2", "year 3"),
           family = font_family, size = 2.20) +
  coord_cartesian(xlim = c(0.15, 19.85), ylim = c(0.28, 5.90), clip = "off") +
  theme_void(base_family = font_family) +
  theme(plot.margin = margin(2, 4, 2, 0))

# Figure 1b: all topic distributions plus two non-extreme, directly labeled examples.
highlight_topics <- topic_medians %>%
  group_by(field) %>%
  mutate(example_decile = ntile(median_eff_j, 10)) %>%
  filter(example_decile %in% c(3, 8)) %>%
  group_by(field, example_decile) %>%
  slice_min(order_by = nchar(topic_name), n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  mutate(
    label_x = if_else(example_decile == 3, 0.08, 1.92),
    leader_start = if_else(example_decile == 3, 0.53, 1.04),
    leader_end = if_else(example_decile == 3, 0.96, 1.47),
    label_hjust = if_else(example_decile == 3, 0, 1),
    label = paste0(str_wrap(topic_name, width = 15),
                   "\nEffJ ", sprintf("%.1f", median_eff_j))
  )

p1b <- ggplot(topic_medians, aes(x = 1, y = log2_median_eff_j)) +
  geom_violin(fill = "#EFEFEF", colour = grey, linewidth = 0.40,
              width = 0.26, scale = "width", trim = TRUE) +
  geom_point(colour = grey, alpha = 0.32, size = 0.24,
             position = position_jitter(width = 0.07, height = 0, seed = 20260830)) +
  stat_summary(fun = median, geom = "crossbar", width = 0.17,
               linewidth = 0.55, colour = ink) +
  geom_segment(
    data = highlight_topics,
    aes(x = leader_start, xend = leader_end, y = log2_median_eff_j,
        yend = log2_median_eff_j, colour = field),
    inherit.aes = FALSE, linewidth = 0.40, show.legend = FALSE
  ) +
  geom_point(
    data = highlight_topics,
    aes(x = 1, y = log2_median_eff_j, fill = field),
    shape = 21, size = 1.20, colour = "white", stroke = 0.20,
    inherit.aes = FALSE, show.legend = FALSE
  ) +
  geom_text(
    data = highlight_topics,
    aes(x = label_x, y = log2_median_eff_j, label = label,
        hjust = label_hjust),
    family = font_family, size = 2.55, lineheight = 0.92,
    colour = ink, inherit.aes = FALSE
  ) +
  facet_wrap(~field, nrow = 3) +
  scale_colour_manual(values = field_colors, guide = "none") +
  scale_fill_manual(values = field_colors, guide = "none") +
  scale_x_continuous(limits = c(0.02, 1.98), breaks = NULL) +
  scale_y_continuous(
    breaks = c(2, 4, 6, 8, 10),
    labels = c("4", "16", "64", "256", "1,024"),
    limits = c(1.4, 10.7)
  ) +
  labs(x = NULL, y = "Median EffJ across observed years (log2 scale)") +
  theme_main() +
  theme(axis.text.x = element_blank(), axis.ticks.x = element_blank(),
        panel.spacing = unit(0.65, "lines"),
        plot.margin = margin(4, 6, 4, 6))

# The original EffJ illustration remains above the descriptive distribution.
p1b_definition <- ggplot() +
  annotate("text", x = 0.20, y = 4.08, label = "Independent variable",
           hjust = 0, family = font_family, fontface = "bold", size = 3.25) +
  annotate("text", x = 0.20, y = 3.40, label = "EffJ",
           hjust = 0, family = font_family, fontface = "bold", size = 4.20,
           colour = green) +
  annotate("text", x = 1.42, y = 3.40,
           label = "Number of similarly sized journals in the subfield-year",
           hjust = 0, family = font_family, size = 2.75) +
  annotate("text", x = 2.45, y = 2.62, label = "One dominant journal",
           family = font_family, size = 2.55) +
  annotate("rect", xmin = c(0.75, 1.65, 2.55, 3.45),
           xmax = c(1.25, 2.15, 3.05, 3.95), ymin = 0.80,
           ymax = c(2.28, 1.13, 1.03, 0.95),
           fill = c(green, grey, grey, grey), colour = NA) +
  annotate("text", x = 2.35, y = 0.38, label = "EffJ near 1",
           family = font_family, fontface = "bold", size = 2.65) +
  annotate("text", x = 7.45, y = 2.62, label = "Four similar journals",
           family = font_family, size = 2.55) +
  annotate("rect", xmin = c(5.65, 6.55, 7.45, 8.35),
           xmax = c(6.15, 7.05, 7.95, 8.85), ymin = 0.80,
           ymax = c(1.72, 1.66, 1.78, 1.70),
           fill = green, colour = NA) +
  annotate("text", x = 7.25, y = 0.38, label = "EffJ near 4",
           family = font_family, fontface = "bold", size = 2.65) +
  coord_cartesian(xlim = c(0.05, 9.75), ylim = c(0.15, 4.28), clip = "off") +
  theme_void(base_family = font_family) +
  theme(plot.margin = margin(1, 5, 0, 5))

# Figure 1c: descriptive CJR values use a paired-rate display rather than
# repeating the EffJ distribution design.
cjr_descriptive <- topic_year %>%
  group_by(field) %>%
  summarise(
    within_rate = 100 * sum(within_ties) / sum(within_possible),
    across_rate = 100 * sum(cross_ties) / sum(cross_possible),
    .groups = "drop"
  ) %>%
  mutate(field = as.character(field)) %>%
  bind_rows(
    topic_year %>%
      summarise(
        field = "Pooled",
        within_rate = 100 * sum(within_ties) / sum(within_possible),
        across_rate = 100 * sum(cross_ties) / sum(cross_possible)
      ),
    .
  ) %>%
  mutate(
    cjr = across_rate / within_rate,
    field = factor(field, levels = rev(c("Pooled", field_order)))
  )

cjr_rate_points <- cjr_descriptive %>%
  pivot_longer(
    cols = c(within_rate, across_rate),
    names_to = "boundary",
    values_to = "rate"
  ) %>%
  mutate(
    boundary = factor(
      boundary,
      levels = c("within_rate", "across_rate"),
      labels = c("Within journal", "Across journals")
    )
  )

cjr_label_x <- max(cjr_descriptive$within_rate) * 1.22
cjr_x_limit <- cjr_label_x + 5.5

p1c <- ggplot(cjr_descriptive, aes(y = field)) +
  geom_segment(
    aes(x = across_rate, xend = within_rate, yend = field),
    colour = light_grey, linewidth = 1.05
  ) +
  geom_point(
    data = cjr_rate_points,
    aes(x = rate, colour = boundary, shape = boundary),
    size = 2.55
  ) +
  geom_text(
    aes(x = across_rate - 0.35, label = sprintf("%.1f%%", across_rate)),
    hjust = 1, family = font_family, size = 2.55, colour = blue
  ) +
  geom_text(
    aes(x = within_rate + 0.35, label = sprintf("%.1f%%", within_rate)),
    hjust = 0, family = font_family, size = 2.55, colour = orange
  ) +
  geom_text(
    aes(x = cjr_label_x, label = sprintf("CJR %.2f", cjr)),
    hjust = 0, family = font_family, fontface = "bold",
    size = 2.65, colour = blue
  ) +
  scale_colour_manual(
    values = c("Within journal" = orange, "Across journals" = blue)
  ) +
  scale_shape_manual(
    values = c("Within journal" = 16, "Across journals" = 17)
  ) +
  scale_x_continuous(
    limits = c(0, cjr_x_limit),
    breaks = seq(0, floor(cjr_x_limit / 5) * 5, by = 5),
    expand = expansion(mult = c(0.01, 0.01))
  ) +
  labs(x = "Citation probability (%)", y = NULL) +
  guides(colour = "none", shape = "none") +
  theme_main() +
  theme(
    legend.position = "none",
    plot.margin = margin(4, 6, 4, 6)
  )

# The original CJR illustration remains above the descriptive paired-rate plot.
p1c_definition <- ggplot() +
  annotate("text", x = 0.20, y = 4.08, label = "Dependent variable",
           hjust = 0, family = font_family, fontface = "bold", size = 3.25) +
  annotate("text", x = 0.20, y = 3.38, label = "CJR",
           hjust = 0, family = font_family, fontface = "bold", size = 4.20,
           colour = blue) +
  annotate("text", x = 1.24, y = 3.38, label = "=",
           hjust = 0, family = font_family, fontface = "bold", size = 3.60) +
  annotate("text", x = 4.35, y = 3.66,
           label = "across-journal citation rate",
           family = font_family, fontface = "bold", size = 2.75,
           colour = blue) +
  annotate("segment", x = 1.82, xend = 6.88, y = 3.37, yend = 3.37,
           colour = ink, linewidth = 0.58) +
  annotate("text", x = 4.35, y = 3.08,
           label = "within-journal citation rate",
           family = font_family, fontface = "bold", size = 2.75,
           colour = orange) +
  annotate("text", x = 2.45, y = 2.42, label = "Within-journal citation",
           family = font_family, fontface = "bold", size = 2.65,
           colour = orange) +
  annotate("text", x = 0.80, y = 1.58, label = "Journal A", hjust = 1,
           family = font_family, size = 2.40) +
  annotate("segment", x = 1.05, xend = 4.35, y = 1.58, yend = 1.58,
           colour = light_grey, linewidth = 1.10) +
  annotate("point", x = c(1.70, 3.65), y = 1.58,
           shape = 22, size = 3.75, fill = ink, colour = ink) +
  annotate("segment", x = 3.50, xend = 1.85, y = 1.58, yend = 1.58,
           arrow = arrow(length = unit(1.15, "mm"), type = "closed"),
           colour = orange, linewidth = 0.85) +
  annotate("text", x = 7.45, y = 2.42, label = "Across-journal citation",
           family = font_family, fontface = "bold", size = 2.65,
           colour = blue) +
  annotate("text", x = 5.55, y = c(1.82, 0.98),
           label = c("Journal A", "Journal B"), hjust = 1,
           family = font_family, size = 2.40) +
  annotate("segment", x = 5.80, xend = 9.30, y = c(1.82, 0.98),
           yend = c(1.82, 0.98), colour = light_grey, linewidth = 1.10) +
  annotate("point", x = c(6.50, 8.55), y = c(1.82, 0.98),
           shape = 22, size = 3.75, fill = ink, colour = ink) +
  annotate("segment", x = 8.40, xend = 6.65, y = 1.06, yend = 1.74,
           arrow = arrow(length = unit(1.15, "mm"), type = "closed"),
           colour = blue, linewidth = 0.85) +
  coord_cartesian(xlim = c(0.05, 9.75), ylim = c(0.40, 4.28), clip = "off") +
  theme_void(base_family = font_family) +
  theme(plot.margin = margin(1, 5, 0, 5))

p1b_panel <- wrap_elements(
  full = free(p1b_definition, side = "l") / p1b +
    plot_layout(heights = c(0.34, 1.00))
)
p1c_panel <- wrap_elements(
  full = free(p1c_definition, side = "l") / p1c +
    plot_layout(heights = c(0.34, 1.00))
)

figure1 <- (free(p1a_sample, side = "l") / (p1b_panel | p1c_panel)) +
  plot_layout(heights = c(0.48, 1.32)) +
  plot_annotation(tag_levels = "a", theme = tag_theme)
save_main(figure1, "figure_1_design_and_effj", 170, 220)

# Figure 2a: define and then plot the cross-journal connection ratio.
p2a_definition <- ggplot() +
  annotate("text", x = 0.45, y = 2.70, label = "Cross-journal connection ratio (CJR)",
           hjust = 0, family = font_family, fontface = "bold", size = 3.0) +
  annotate("rect", xmin = 0.45, xmax = 1.80, ymin = 1.15, ymax = 2.30,
           fill = "#EAF4FB", colour = NA) +
  annotate("point", x = c(0.72, 1.52), y = c(1.72, 1.72),
           shape = 21, size = 3.6, fill = "white", colour = ink, stroke = 0.5) +
  annotate("segment", x = 1.44, xend = 0.80, y = 1.72, yend = 1.72,
           arrow = arrow(length = unit(1.2, "mm"), type = "closed"),
           colour = blue, linewidth = 0.8) +
  annotate("text", x = 1.12, y = 1.00,
           label = "cross-journal links\n÷ possible cross-journal pairs",
           family = font_family, size = 2.2, lineheight = 0.95) +
  annotate("text", x = 2.18, y = 1.72, label = "÷",
           family = font_family, fontface = "bold", size = 4.0) +
  annotate("rect", xmin = 2.55, xmax = 3.90, ymin = 1.15, ymax = 2.30,
           fill = "#FFF2E8", colour = NA) +
  annotate("point", x = c(2.82, 3.62), y = c(1.72, 1.72),
           shape = 21, size = 3.6, fill = "white", colour = ink, stroke = 0.5) +
  annotate("segment", x = 3.54, xend = 2.90, y = 1.72, yend = 1.72,
           arrow = arrow(length = unit(1.2, "mm"), type = "closed"),
           colour = orange, linewidth = 0.8) +
  annotate("text", x = 3.22, y = 1.00,
           label = "within-journal links\n÷ possible within-journal pairs",
           family = font_family, size = 2.2, lineheight = 0.95) +
  annotate("text", x = 4.45, y = 1.72, label = "= 1 when the two\nlink probabilities are equal",
           hjust = 0, family = font_family, size = 2.25, lineheight = 0.95) +
  coord_cartesian(xlim = c(0.25, 6.0), ylim = c(0.72, 2.95), clip = "off") +
  theme_void(base_family = font_family)

bins <- topic_year %>%
  group_by(field) %>%
  mutate(bin = ntile(log2_eff_j, 10)) %>%
  group_by(field, bin) %>%
  summarise(
    log2_eff_j = weighted.mean(log2_eff_j, focal_families),
    connection_ratio = exp(weighted.mean(log_cross_within_rate_ratio, focal_families)),
    .groups = "drop"
  )

p2a_scatter <- ggplot(topic_year, aes(x = log2_eff_j, y = connection_ratio)) +
  geom_hline(yintercept = 1, colour = light_grey, linewidth = 0.4) +
  geom_point(colour = grey, size = 0.45, alpha = 0.20) +
  geom_smooth(aes(colour = field), method = "lm", se = FALSE,
              linewidth = 0.7, show.legend = FALSE) +
  geom_point(
    data = bins,
    aes(x = log2_eff_j, y = connection_ratio, colour = field),
    inherit.aes = FALSE,
    size = 1.7,
    show.legend = FALSE
  ) +
  facet_wrap(~field, nrow = 2) +
  scale_colour_manual(values = field_colors) +
  scale_y_log10(
    breaks = c(0.01, 0.03, 0.10, 0.30, 1, 3),
    labels = c("0.01", "0.03", "0.10", "0.30", "1", "3"),
    limits = c(0.007, 5.5)
  ) +
  labs(x = "Topic-year EffJ (log₂)", y = "Cross-journal connection ratio (CJR)") +
  theme_main(base_size = 7.0)

p2a <- wrap_elements(p2a_definition / p2a_scatter + plot_layout(heights = c(0.36, 1.0)))

self_results <- bind_rows(
  read_csv(
    file.path(result_dir, "temporal_researcher_coordination_fe_results.csv"),
    show_col_types = FALSE
  ) %>%
    filter(universe == "full", specification == "context_controls") %>%
    mutate(model_level = "corresponding_author"),
  read_csv(
    file.path(result_dir, "temporal_coordination_fe_results.csv"),
    show_col_types = FALSE
  ) %>%
    filter(universe == "full", specification == "context_controls") %>%
    mutate(model_level = "topic_year")
) %>%
  filter(analytic_field %in% c(
    "pooled", "biology", "chemistry", "geology",
    "materials_science", "medicine", "physics"
  )) %>%
  bind_cols(percent_ci_from_log(
    .$percent_change_for_effj_doubling,
    .$standard_error_log_rate_doubling
  )) %>%
  mutate(
    level_plain = recode(
      model_level,
      corresponding_author = "Across focal-paper families led by the same corresponding author at the same institution",
      topic_year = "Within subfield across years"
    ),
    model_short = recode(
      model_level,
      corresponding_author = "Same corresponding author + institution",
      topic_year = "Same topic + year"
    )
  )

pooled_main <- self_results %>%
  filter(analytic_field == "pooled") %>%
  mutate(
    level_plain = factor(
      str_wrap(level_plain, width = 44),
      levels = rev(str_wrap(c(
        "Across focal-paper families led by the same corresponding author at the same institution",
        "Within subfield across years"
      ), width = 44))
    ),
    estimate_label = sprintf(
      "%.2f%%  [%.2f, %.2f]",
      percent_change_for_effj_doubling, ci_low_percent, ci_high_percent
    )
  )

p2b <- ggplot(pooled_main, aes(x = percent_change_for_effj_doubling, y = level_plain)) +
  geom_vline(xintercept = 0, colour = dark_grey, linewidth = 0.4) +
  geom_errorbar(
    aes(xmin = ci_low_percent, xmax = ci_high_percent),
    orientation = "y", width = 0, linewidth = 0.75, colour = blue
  ) +
  geom_point(size = 2.8, colour = blue) +
  geom_text(
    aes(x = ci_high_percent + 0.25, label = estimate_label),
    hjust = 0, family = font_family, size = 2.35, colour = ink
  ) +
  scale_x_continuous(limits = c(-13.0, 1.4), breaks = c(-12, -8, -4, 0)) +
  labs(x = NULL, y = "EffJ doubles:\nchange in CJR (%)") +
  theme_main()

field_main <- self_results %>%
  filter(analytic_field != "pooled") %>%
  mutate(
    field = factor(clean_field(analytic_field), levels = rev(field_order)),
    estimate_label = sprintf(
      "%.1f [%.1f, %.1f]",
      percent_change_for_effj_doubling, ci_low_percent, ci_high_percent
    )
  )

p2c <- ggplot(
  field_main,
  aes(x = percent_change_for_effj_doubling, y = field, colour = field)
) +
  geom_vline(xintercept = 0, colour = dark_grey, linewidth = 0.4) +
  geom_errorbar(
    aes(xmin = ci_low_percent, xmax = ci_high_percent),
    orientation = "y", width = 0, linewidth = 0.6
  ) +
  geom_point(size = 2.2) +
  geom_text(
    aes(x = 5.0, label = estimate_label),
    hjust = 0, family = font_family, size = 1.95, colour = ink
  ) +
  annotate("text", x = 5.0, y = 6.55, label = "estimate [95% CI]",
           hjust = 0, family = font_family, size = 2.0, fontface = "bold") +
  facet_wrap(~model_short, nrow = 1) +
  scale_colour_manual(values = field_colors, guide = "none") +
  scale_x_continuous(limits = c(-13.0, 13.0), breaks = c(-12, -8, -4, 0, 4)) +
  labs(
    x = "Adjusted percent change in CJR when EffJ doubles",
    y = NULL,
    title = "Field heterogeneity"
  ) +
  theme_main(base_size = 7.0)

# Figure 2a: define the journal boundary, show the observed baseline difference,
# and then define CJR.
baseline_rates <- topic_year %>%
  summarise(
    within_rate = 100 * sum(within_ties) / sum(within_possible),
    across_rate = 100 * sum(cross_ties) / sum(cross_possible),
    cjr = across_rate / within_rate
  )

within_bar_end <- 5.10 + 1.25
across_bar_end <- 5.10 + 1.25 * baseline_rates$across_rate / baseline_rates$within_rate

p2a <- ggplot() +
  annotate("rect", xmin = 0.78, xmax = 3.45, ymin = 2.58, ymax = 3.18,
           fill = "#FFF2E8", colour = NA) +
  annotate("rect", xmin = 0.78, xmax = 3.45, ymin = 1.68, ymax = 2.28,
           fill = "#EAF4FB", colour = NA) +
  annotate("rect", xmin = 0.78, xmax = 3.45, ymin = 0.78, ymax = 1.38,
           fill = "#EAF7F1", colour = NA) +
  annotate("text", x = 0.64, y = c(2.88, 1.98, 1.08),
           label = c("Journal A", "Journal B", "Journal C"), hjust = 1,
           family = font_family, fontface = "bold", size = 3.10) +
  annotate("point", x = c(1.20, 2.00), y = c(2.88, 2.88),
           shape = 21, size = 4.0, fill = "white", colour = ink, stroke = 0.55) +
  annotate("segment", x = 1.92, xend = 1.28, y = 2.88, yend = 2.88,
           arrow = arrow(length = unit(1.3, "mm"), type = "closed"),
           colour = orange, linewidth = 0.9) +
  annotate("text", x = 1.60, y = 3.43, label = "within-journal citation",
           family = font_family, fontface = "bold", size = 2.95, colour = orange) +
  annotate("point", x = c(2.88, 2.88), y = c(1.98, 1.08),
           shape = 21, size = 4.0, fill = "white", colour = ink, stroke = 0.55) +
  annotate("segment", x = 2.88, xend = 2.88, y = 1.90, yend = 1.16,
           arrow = arrow(length = unit(1.3, "mm"), type = "closed"),
           colour = blue, linewidth = 0.9) +
  annotate("text", x = 2.70, y = 1.53, label = "across-journal\ncitation",
           hjust = 1, family = font_family, fontface = "bold", size = 2.95,
           lineheight = 0.95, colour = blue) +
  annotate("text", x = 3.72, y = 3.22, label = "Observed citation probability",
           hjust = 0, family = font_family, fontface = "bold", size = 3.15) +
  annotate("text", x = 3.72, y = 2.70, label = "Within journal",
           hjust = 0, family = font_family, size = 2.90, colour = orange) +
  annotate("segment", x = 5.10, xend = within_bar_end, y = 2.70, yend = 2.70,
           colour = orange, linewidth = 3.2, lineend = "butt") +
  annotate("text", x = 6.50, y = 2.70,
           label = sprintf("%.1f%%", baseline_rates$within_rate),
           hjust = 0, family = font_family, fontface = "bold", size = 2.90,
           colour = orange) +
  annotate("text", x = 3.72, y = 2.20, label = "Across journals",
           hjust = 0, family = font_family, size = 2.90, colour = blue) +
  annotate("segment", x = 5.10, xend = across_bar_end, y = 2.20, yend = 2.20,
           colour = blue, linewidth = 3.2, lineend = "butt") +
  annotate("text", x = 6.50, y = 2.20,
           label = sprintf("%.2f%%", baseline_rates$across_rate),
           hjust = 0, family = font_family, fontface = "bold", size = 2.90,
           colour = blue) +
  annotate("text", x = 3.72, y = 1.42, label = "CJR =",
           hjust = 0, vjust = 0.5, family = font_family, fontface = "bold", size = 3.70) +
  annotate("text", x = 5.18, y = 1.68, label = "across-journal probability",
           family = font_family, size = 2.70) +
  annotate("segment", x = 4.45, xend = 5.92, y = 1.43, yend = 1.43,
           colour = ink, linewidth = 0.55) +
  annotate("text", x = 5.18, y = 1.15, label = "within-journal probability",
           family = font_family, size = 2.70) +
  annotate("text", x = 6.20, y = 1.42,
           label = sprintf("= %.2f", baseline_rates$cjr),
           hjust = 0, vjust = 0.5, family = font_family, fontface = "bold", size = 3.45) +
  annotate("text", x = 3.72, y = 0.62,
           label = "CJR < 1: within-journal citation is more likely",
           hjust = 0, family = font_family, size = 2.75) +
  coord_cartesian(xlim = c(0.08, 7.15), ylim = c(0.35, 3.62), clip = "off") +
  theme_void(base_family = font_family) +
  theme(plot.margin = margin(1, 2, 1, 0))

# Figure 2a: descriptive topic-year relationship in all six fields.
p2b <- ggplot(topic_year, aes(x = log2_eff_j, y = connection_ratio)) +
  geom_hline(yintercept = 1, colour = light_grey, linewidth = 0.4) +
  geom_point(colour = grey, size = 0.42, alpha = 0.20) +
  geom_smooth(aes(colour = field), method = "lm", se = FALSE,
              linewidth = 0.75, show.legend = FALSE) +
  geom_point(data = bins,
             aes(x = log2_eff_j, y = connection_ratio, colour = field),
             inherit.aes = FALSE, size = 1.55, show.legend = FALSE) +
  facet_wrap(~field, nrow = 2) +
  scale_colour_manual(values = field_colors) +
  scale_y_log10(
    breaks = c(0.01, 0.03, 0.10, 0.30, 1, 3),
    labels = c("0.01", "0.03", "0.10", "0.30", "1", "3"),
    limits = c(0.007, 5.5)
  ) +
  labs(x = "EffJ for the subfield and publication year (log2)",
       y = "Cross-journal connection ratio (CJR)") +
  theme_main() +
  theme(plot.margin = margin(4, 5, 4, 11))

comparison_labels <- c(
  corresponding_author = "Same author at the\nsame institution",
  topic_year = "Within subfield\nacross years"
)

pooled_main <- self_results %>%
  filter(analytic_field == "pooled") %>%
  mutate(
    comparison = comparison_labels[model_level],
    comparison = factor(comparison, levels = comparison_labels),
    y_pos = 1,
    estimate_label = sprintf("%.2f%% [%.2f, %.2f]",
                             percent_change_for_effj_doubling,
                             ci_low_percent, ci_high_percent)
  )

# Figure 2b: one compact facet per comparison avoids long category labels.
p2c <- ggplot(pooled_main, aes(x = percent_change_for_effj_doubling, y = y_pos)) +
  geom_vline(xintercept = 0, colour = dark_grey, linewidth = 0.4) +
  geom_errorbar(aes(xmin = ci_low_percent, xmax = ci_high_percent),
                orientation = "y", width = 0, linewidth = 0.75, colour = blue) +
  geom_point(size = 2.6, colour = blue) +
  geom_text(aes(y = y_pos + 0.18, label = estimate_label),
            family = font_family, size = 3.00, colour = ink) +
  facet_wrap(~comparison, nrow = 1) +
  scale_y_continuous(breaks = NULL, limits = c(0.82, 1.32)) +
  scale_x_continuous(limits = c(-13.0, 1.4), breaks = c(-12, -8, -4, 0)) +
  labs(
    x = "Adjusted percent change in CJR when EffJ doubles",
    y = NULL
  ) +
  theme_main() +
  theme(plot.margin = margin(1, 5, 2, 5))

field_main <- self_results %>%
  filter(analytic_field != "pooled") %>%
  mutate(
    field = factor(clean_field(analytic_field), levels = rev(field_order)),
    field_num = as.numeric(field),
    comparison = factor(comparison_labels[model_level],
                        levels = comparison_labels[c("corresponding_author", "topic_year")]),
    estimate_label = sprintf("%.1f [%.1f, %.1f]",
                             percent_change_for_effj_doubling,
                             ci_low_percent, ci_high_percent)
  )

# Figure 2c: field heterogeneity with estimate and interval above every point.
p2d <- ggplot(field_main,
              aes(x = percent_change_for_effj_doubling, y = field_num, colour = field)) +
  geom_vline(xintercept = 0, colour = dark_grey, linewidth = 0.4) +
  geom_errorbar(aes(xmin = ci_low_percent, xmax = ci_high_percent),
                orientation = "y", width = 0, linewidth = 0.6) +
  geom_point(size = 2.1) +
  geom_text(aes(y = field_num + 0.23, label = estimate_label),
            family = font_family, size = 2.45, colour = ink) +
  facet_wrap(~comparison, nrow = 1) +
  scale_colour_manual(values = field_colors, guide = "none") +
  scale_y_continuous(breaks = seq_along(field_order), labels = rev(field_order),
                     limits = c(0.65, 6.55)) +
  scale_x_continuous(
    limits = c(-26.0, 8.0), breaks = c(-24, -16, -8, 0, 8)
  ) +
  labs(
    x = "Adjusted percent change in CJR when EffJ doubles",
    y = NULL,
    title = "Field heterogeneity"
  ) +
  theme_main() +
  theme(plot.margin = margin(2, 5, 2, 5))

figure2 <- free(p2b, side = "l") /
  free(p2c, side = "l") /
  p2d +
  plot_layout(heights = c(1.05, 0.36, 0.92)) +
  plot_annotation(tag_levels = "a", theme = tag_theme_figure2)
save_main(figure2, "figure_2_connection_ratio_and_results", 160)

# Figure 3: graph definition and estimates for later uptake of early work.
handoff <- read_csv(
  "results/cumulative_handoff/cumulative_handoff_results.csv",
  show_col_types = FALSE
) %>%
  filter(universe == "full")

subfield_panel <- read_parquet(
  "results/cumulative_handoff/cumulative_handoff_subfield_panel.parquet",
  as_data_frame = TRUE
) %>%
  filter(universe == "full")

subfield_unique <- subfield_panel %>%
  distinct(analytic_field, topic_year_id, early_coordination_gap)
subfield_sd <- bind_rows(
  subfield_unique %>%
    summarise(analytic_field = "pooled", exposure_sd = sd(early_coordination_gap)),
  subfield_unique %>%
    group_by(analytic_field) %>%
    summarise(exposure_sd = sd(early_coordination_gap), .groups = "drop")
)

family_effects <- read_csv(
  "results/cumulative_handoff/later_uptake_cross_share_results.csv",
  show_col_types = FALSE
) %>%
  filter(
    universe == "full",
    cohort == "2015-2021",
    specification ==
      "Total early ties and cross-versus-within opportunities"
  ) %>%
  mutate(
    effect = later_uptake_change_percent_for_odds_doubling,
    lower = confidence_low,
    upper = confidence_high,
    field = factor(clean_field(analytic_field), levels = rev(c("Pooled", field_order))),
    estimate_label = sprintf("%.1f [%.1f, %.1f]", effect, lower, upper)
  )

subfield_effects <- handoff %>%
  filter(
    scale == "subfield_cross_boundary_handoff",
    analytic_field %in% c("pooled", "biology", "chemistry", "geology",
                          "materials_science", "medicine", "physics")
  ) %>%
  left_join(subfield_sd, by = "analytic_field") %>%
  mutate(
    effect = percent_change_per_one_sd_early_coordination_gap,
    lower = 100 * (exp((estimate_per_log_gap - 1.96 * standard_error) * exposure_sd) - 1),
    upper = 100 * (exp((estimate_per_log_gap + 1.96 * standard_error) * exposure_sd) - 1),
    field = factor(clean_field(analytic_field), levels = rev(c("Pooled", field_order))),
    estimate_label = sprintf("%.1f [%.1f, %.1f]", effect, lower, upper)
  )

p3a <- ggplot() +
  annotate("rect", xmin = 1.10, xmax = 5.85, ymin = 2.62, ymax = 3.30,
           fill = "#FFF2E8", colour = NA) +
  annotate("rect", xmin = 1.10, xmax = 5.85, ymin = 1.72, ymax = 2.40,
           fill = "#EAF4FB", colour = NA) +
  annotate("rect", xmin = 1.10, xmax = 5.85, ymin = 0.82, ymax = 1.50,
           fill = "#EAF7F1", colour = NA) +
  annotate("text", x = 5.98, y = c(2.96, 2.06, 1.16),
           label = c("Journal A", "Journal B", "Journal C"),
           hjust = 0, family = font_family, fontface = "bold", size = 2.3) +
  annotate("point", x = 0.55, y = 2.06, shape = 22, size = 5.6,
           fill = "white", colour = ink, stroke = 0.6) +
  annotate("text", x = 0.55, y = 2.09, label = "P0",
           family = font_family, fontface = "bold", size = 2.3) +
  annotate("text", x = 0.55, y = 0.55, label = "year 0",
           family = font_family, size = 2.1) +
  annotate("point", x = c(1.85, 2.45, 3.05), y = c(2.96, 2.06, 1.16),
           shape = 21, size = 4.0, fill = "white", colour = ink, stroke = 0.5) +
  annotate("text", x = c(1.85, 2.45, 3.05), y = c(2.96, 2.06, 1.16),
           label = c("E1", "E2", "E3"), family = font_family,
           fontface = "bold", size = 2.0) +
  annotate("segment", x = c(1.79, 2.39, 2.99), y = c(2.93, 2.06, 1.18),
           xend = 0.64, yend = 2.06,
           arrow = arrow(length = unit(1.1, "mm"), type = "closed"),
           colour = dark_grey, linewidth = 0.3) +
  annotate("segment", x = 2.39, xend = 1.93, y = 2.10, yend = 2.91,
           arrow = arrow(length = unit(1.3, "mm"), type = "closed"),
           colour = blue, linewidth = 0.85) +
  annotate("text", x = 2.28, y = 3.55,
           label = "early across-journal citation",
           family = font_family, size = 2.25, colour = blue, fontface = "bold") +
  annotate("point", x = c(4.65, 5.10), y = c(2.96, 1.16),
           shape = 21, size = 4.2, fill = "white", colour = ink, stroke = 0.5) +
  annotate("text", x = c(4.65, 5.10), y = c(2.96, 1.16),
           label = c("L1", "L2"), family = font_family,
           fontface = "bold", size = 2.0) +
  annotate("curve", x = 4.59, y = 2.92, xend = 2.54, yend = 2.12,
           curvature = 0.15,
           arrow = arrow(length = unit(1.4, "mm"), type = "closed"),
           colour = green, linewidth = 1.0) +
  annotate("text", x = 4.55, y = 3.58,
           label = "later uptake = later paper cites early follow-on work",
           family = font_family, size = 2.25, colour = green, fontface = "bold") +
  annotate("segment", x = 0.35, xend = 5.55, y = 0.42, yend = 0.42,
           arrow = arrow(length = unit(1.2, "mm"), type = "closed"),
           colour = ink, linewidth = 0.35) +
  annotate("text", x = 2.45, y = 0.18, label = "early papers: years 1-3",
           family = font_family, size = 2.2) +
  annotate("text", x = 4.88, y = 0.18, label = "later papers: years 4-5",
           family = font_family, size = 2.2) +
  coord_cartesian(xlim = c(0.18, 6.75), ylim = c(0.02, 3.82), clip = "off") +
  theme_void(base_family = font_family)

# Revised Figure 3a: both within- and different-journal later uptake are explicit.
p3a <- ggplot() +
  annotate("rect", xmin = 1.10, xmax = 5.85, ymin = 2.62, ymax = 3.30,
           fill = "#FFF2E8", colour = NA) +
  annotate("rect", xmin = 1.10, xmax = 5.85, ymin = 1.72, ymax = 2.40,
           fill = "#EAF4FB", colour = NA) +
  annotate("rect", xmin = 1.10, xmax = 5.85, ymin = 0.82, ymax = 1.50,
           fill = "#EAF7F1", colour = NA) +
  annotate("text", x = 5.98, y = c(2.96, 2.06, 1.16),
           label = c("Journal A", "Journal B", "Journal C"),
           hjust = 0, family = font_family, fontface = "bold", size = 3.00) +
  annotate("point", x = 0.55, y = 2.06, shape = 22, size = 5.4,
           fill = "white", colour = ink, stroke = 0.6) +
  annotate("text", x = 0.55, y = 2.09, label = "P0",
           family = font_family, fontface = "bold", size = 3.00) +
  annotate("text", x = 0.55, y = 0.55, label = "year 0",
           family = font_family, size = 2.75) +
  annotate("point", x = c(1.85, 2.45, 3.05), y = c(2.96, 2.06, 1.16),
           shape = 21, size = 3.8, fill = "white", colour = ink, stroke = 0.5) +
  annotate("text", x = c(1.85, 2.45, 3.05), y = c(2.96, 2.06, 1.16),
           label = c("E1", "E2", "E3"), family = font_family,
           fontface = "bold", size = 2.60) +
  annotate("segment", x = c(1.79, 2.39, 2.99), y = c(2.93, 2.06, 1.18),
           xend = 0.64, yend = 2.06,
           arrow = arrow(length = unit(1.1, "mm"), type = "closed"),
           colour = dark_grey, linewidth = 0.3) +
  annotate("segment", x = 2.39, xend = 1.93, y = 2.10, yend = 2.91,
           arrow = arrow(length = unit(1.3, "mm"), type = "closed"),
           colour = blue, linewidth = 0.85) +
  annotate("text", x = 2.30, y = 3.55, label = "early across-journal citation",
           family = font_family, size = 2.90, colour = blue, fontface = "bold") +
  annotate("point", x = c(4.55, 5.15), y = c(2.06, 2.96),
           shape = 21, size = 4.0, fill = "white", colour = ink, stroke = 0.5) +
  annotate("text", x = c(4.55, 5.15), y = c(2.06, 2.96),
           label = c("L1", "L2"), family = font_family,
           fontface = "bold", size = 2.60) +
  annotate("segment", x = 4.47, xend = 2.54, y = 2.06, yend = 2.06,
           arrow = arrow(length = unit(1.3, "mm"), type = "closed"),
           colour = orange, linewidth = 0.9) +
  annotate("curve", x = 5.08, y = 2.92, xend = 2.53, yend = 2.12,
           curvature = 0.16,
           arrow = arrow(length = unit(1.3, "mm"), type = "closed"),
           colour = green, linewidth = 0.9) +
  annotate("text", x = 4.10, y = 1.72, label = "within-journal uptake",
           family = font_family, size = 2.75, colour = orange, fontface = "bold") +
  annotate("text", x = 4.60, y = 3.55, label = "different-journal uptake",
           family = font_family, size = 2.75, colour = green, fontface = "bold") +
  annotate("text", x = 3.85, y = 0.66,
           label = "Later uptake: a later paper cites early follow-on work\nAny-journal uptake counts either colored arrow",
           family = font_family, size = 2.80, lineheight = 0.95) +
  annotate("segment", x = 0.35, xend = 5.55, y = 0.32, yend = 0.32,
           arrow = arrow(length = unit(1.2, "mm"), type = "closed"),
           colour = ink, linewidth = 0.35) +
  annotate("text", x = 2.45, y = 0.08, label = "early papers: years 1-3",
           family = font_family, size = 2.80) +
  annotate("text", x = 4.88, y = 0.08, label = "later papers: years 4-5",
           family = font_family, size = 2.80) +
  coord_cartesian(xlim = c(0.18, 6.75), ylim = c(-0.05, 3.82), clip = "off") +
  theme_void(base_family = font_family)

plot_handoff <- function(data, color, title_text, axis_text, x_limits, x_breaks) {
  plot_data <- data %>% mutate(y_pos = as.numeric(field))
  ggplot(plot_data, aes(x = effect, y = y_pos)) +
    geom_vline(xintercept = 0, colour = dark_grey, linewidth = 0.4) +
    geom_hline(yintercept = 6.5, colour = dark_grey, linewidth = 0.45,
               linetype = "dashed") +
    geom_errorbar(
      aes(xmin = lower, xmax = upper, colour = analytic_field == "pooled"),
      orientation = "y", width = 0, linewidth = 0.65
    ) +
    geom_point(
      aes(colour = analytic_field == "pooled", shape = analytic_field == "pooled"),
      size = 2.3
    ) +
    geom_text(
      aes(y = y_pos + 0.23, label = estimate_label),
      family = font_family, size = 2.45, colour = ink
    ) +
    scale_colour_manual(values = c(`TRUE` = ink, `FALSE` = color), guide = "none") +
    scale_shape_manual(values = c(`TRUE` = 18, `FALSE` = 16), guide = "none") +
    scale_y_continuous(breaks = seq_along(levels(plot_data$field)),
                       labels = levels(plot_data$field), limits = c(0.65, 7.55)) +
    scale_x_continuous(limits = x_limits, breaks = x_breaks) +
    labs(x = axis_text, y = NULL, title = title_text) +
    theme_main()
}

p3b <- plot_handoff(
  family_effects,
  blue,
  "Later papers citing early work",
  "Estimated change (%) when early cross-versus-within\ncitation odds double",
  c(-0.1, 3.1),
  c(0, 1, 2, 3)
)
p3c <- plot_handoff(
  subfield_effects,
  green,
  "Later citations crossing journals",
  "Estimated change (%) when early CJR is\none standard deviation higher",
  c(-1.5, 10.5),
  c(0, 2, 4, 6)
)

figure3 <- p3a / (p3b | p3c) +
  plot_layout(heights = c(0.70, 1.20)) +
  plot_annotation(tag_levels = "a", theme = tag_theme)
save_main(figure3, "figure_3_later_uptake", 175)

cat("Rendered manuscript Figures 1-3.\n")
