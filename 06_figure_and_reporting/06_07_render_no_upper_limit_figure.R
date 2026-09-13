#!/usr/bin/env Rscript

# Render Figure S4: the sensitivity analysis that removes the 20-paper upper bound.

Sys.setenv(XDG_CACHE_HOME = "/private/tmp/journal_structure_font_cache")
dir.create(Sys.getenv("XDG_CACHE_HOME"), recursive = TRUE, showWarnings = FALSE)

suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(patchwork)
  library(readr)
})

result_dir <- "results/direct_outcome_gap"
figure_dir <- file.path(result_dir, "figures", "appendix")
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)

font_family <- "Arial"
ink <- "#171717"
blue <- "#0072B2"
light_blue <- "#9ECAE1"
dark_grey <- "#606060"
light_grey <- "#D4D4D4"

field_order <- c(
  "Biology", "Chemistry", "Geology", "Materials science", "Medicine", "Physics"
)

clean_field <- function(x) {
  recode(
    x,
    biology = "Biology",
    chemistry = "Chemistry",
    geology = "Geology",
    materials_science = "Materials science",
    medicine = "Medicine",
    physics = "Physics"
  )
}

percent_ci_from_log <- function(effect, standard_error) {
  log_effect <- log1p(effect / 100)
  tibble(
    lower = 100 * (exp(log_effect - 1.96 * standard_error) - 1),
    upper = 100 * (exp(log_effect + 1.96 * standard_error) - 1)
  )
}

theme_s4 <- function() {
  theme_classic(base_size = 11.5, base_family = font_family) +
    theme(
      axis.title = element_text(size = 11.5, colour = ink),
      axis.text = element_text(size = 10.5, colour = ink),
      axis.title.y = element_text(margin = margin(r = 7)),
      axis.line = element_line(linewidth = 0.45, colour = ink),
      axis.ticks = element_line(linewidth = 0.45, colour = ink),
      axis.ticks.length = unit(1.6, "mm"),
      strip.background = element_blank(),
      strip.text = element_text(size = 11.2, face = "bold", hjust = 0),
      legend.position = "top",
      legend.justification = "left",
      legend.title = element_blank(),
      legend.text = element_text(size = 10.5),
      legend.key.width = unit(7, "mm"),
      plot.title = element_text(size = 12.5, face = "bold", hjust = 0),
      plot.subtitle = element_text(size = 10.5, colour = dark_grey, hjust = 0),
      plot.title.position = "plot",
      plot.margin = margin(7, 9, 7, 9)
    )
}

sample_values <- c(
  "2–20 (primary)" = ink,
  "No upper limit" = blue
)

sample_shapes <- c(
  "2–20 (primary)" = 16,
  "No upper limit" = 17
)

comparison_labels <- c(
  researcher = "Same author\nat the same\ninstitution",
  topic = "Same subfield\nand year"
)

read_model <- function(path, level, sample_label) {
  raw <- read_csv(path, show_col_types = FALSE) %>%
    filter(specification == "context_controls")
  ci <- percent_ci_from_log(
    raw$percent_change_for_effj_doubling,
    raw$standard_error_log_rate_doubling
  )
  raw %>%
    mutate(
      level = level,
      sample = sample_label,
      lower = ci$lower,
      upper = ci$upper
    )
}

model_data <- bind_rows(
  read_model(
    file.path(result_dir, "temporal_researcher_coordination_fe_results.csv"),
    "researcher", "2–20 (primary)"
  ),
  read_model(
    file.path(result_dir, "temporal_coordination_fe_results.csv"),
    "topic", "2–20 (primary)"
  ),
  read_model(
    file.path(result_dir, "no_upper_limit_temporal_researcher_coordination_fe_results.csv"),
    "researcher", "No upper limit"
  ),
  read_model(
    file.path(result_dir, "no_upper_limit_temporal_coordination_fe_results.csv"),
    "topic", "No upper limit"
  )
) %>%
  mutate(
    sample = factor(sample, levels = names(sample_values)),
    comparison = factor(comparison_labels[level], levels = comparison_labels),
    universe_label = recode(
      universe,
      full = "Full OpenAlex",
      scimago = "SCImago-matched"
    )
  )

# Panel a: show why the no-upper-limit analysis is dominated by large families.
family_data <- read_csv(
  file.path(result_dir, "no_upper_limit_family_size_contribution_by_field.csv"),
  show_col_types = FALSE
) %>%
  filter(universe == "full") %>%
  group_by(size_group) %>%
  summarise(
    focal_papers = sum(focal_families),
    earlier_later_pairs = sum(possible_pairs),
    .groups = "drop"
  )

large_family_share <- family_data %>%
  summarise(
    focal_papers = 100 * focal_papers[size_group == "21+"] / sum(focal_papers),
    earlier_later_pairs =
      100 * earlier_later_pairs[size_group == "21+"] / sum(earlier_later_pairs)
  ) %>%
  tidyr::pivot_longer(
    everything(), names_to = "measure", values_to = "share"
  ) %>%
  mutate(
    measure = recode(
      measure,
      focal_papers = "Focal papers",
      earlier_later_pairs = "Comparisons used\nto calculate CJR"
    ),
    measure = factor(
      measure,
      levels = rev(c("Focal papers", "Comparisons used\nto calculate CJR"))
    ),
    label = sprintf("%.1f%%", share)
  )

s4a <- ggplot(large_family_share, aes(x = share, y = measure)) +
  geom_segment(
    aes(x = 0, xend = share, yend = measure),
    linewidth = 2.1, colour = light_blue, lineend = "round"
  ) +
  geom_point(size = 3.1, shape = 16, colour = blue) +
  geom_text(
    aes(label = label),
    nudge_y = 0.18, family = font_family, fontface = "bold", size = 3.55,
    colour = ink
  ) +
  scale_x_continuous(
    limits = c(0, 100), breaks = c(0, 25, 50, 75, 100),
    expand = expansion(mult = c(0, 0.02))
  ) +
  labs(
    x = paste0(
      "Share contributed by focal papers\n",
      "with more than 20 follow-on\n",
      "papers (%)"
    ),
    y = NULL,
    title = "Why the upper limit matters",
    subtitle = paste0(
      "For each focal paper, every two\n",
      "follow-on papers are compared.\n",
      "Did the paper published later cite\n",
      "the paper published earlier?"
    ),
    tag = "a"
  ) +
  theme_s4() +
  theme(
    legend.position = "none",
    plot.tag = element_text(size = 11.5, face = "bold"),
    plot.tag.position = "topleft"
  )

# Panel b: pooled primary estimand in both journal universes.
pooled_data <- model_data %>%
  filter(analytic_field == "pooled") %>%
  mutate(
    universe_label = factor(
      universe_label,
      levels = rev(c("Full OpenAlex", "SCImago-matched"))
    ),
    y_base = as.numeric(universe_label),
    y_pos = y_base + if_else(sample == "2–20 (primary)", 0.15, -0.15),
    label_y = y_pos + if_else(sample == "2–20 (primary)", 0.22, -0.22),
    estimate_label = sprintf("%.1f [%.1f, %.1f]",
                             percent_change_for_effj_doubling, lower, upper)
  )

s4b <- ggplot(
  pooled_data,
  aes(x = percent_change_for_effj_doubling, y = y_pos, colour = sample, shape = sample)
) +
  geom_vline(xintercept = 0, colour = dark_grey, linewidth = 0.45) +
  geom_errorbar(
    aes(xmin = lower, xmax = upper), orientation = "y",
    width = 0, linewidth = 0.8
  ) +
  geom_point(size = 2.8) +
  geom_label(
    aes(x = 1.2, y = label_y, label = estimate_label),
    hjust = 1, family = font_family, size = 2.55, colour = ink,
    fill = "white", linewidth = 0, label.padding = unit(0.35, "mm")
  ) +
  facet_wrap(~comparison, nrow = 1) +
  scale_y_continuous(
    breaks = seq_along(levels(pooled_data$universe_label)),
    labels = levels(pooled_data$universe_label),
    limits = c(0.48, 2.58)
  ) +
  scale_x_continuous(
    limits = c(-32, 2), breaks = c(-30, -20, -10, 0)
  ) +
  scale_colour_manual(
    values = sample_values,
    labels = c("2–20", "No upper limit")
  ) +
  scale_shape_manual(
    values = sample_shapes,
    labels = c("2–20", "No upper limit")
  ) +
  labs(
    x = "Adjusted percent change in CJR\nwhen EffJ doubles",
    y = NULL,
    title = "Pooled CJR estimates",
    tag = "b"
  ) +
  theme_s4() +
  theme(
    legend.text = element_text(size = 10.0),
    legend.key.width = unit(4.5, "mm"),
    legend.spacing.x = unit(1.0, "mm"),
    plot.tag = element_text(size = 11.5, face = "bold"),
    plot.tag.position = "topleft"
  )

# Panel c: field-specific primary estimand in Full OpenAlex.
field_data <- model_data %>%
  filter(
    universe == "full",
    analytic_field %in% c(
      "biology", "chemistry", "geology", "materials_science", "medicine", "physics"
    )
  ) %>%
  mutate(
    field = factor(clean_field(analytic_field), levels = rev(field_order)),
    y_base = as.numeric(field),
    y_pos = y_base + if_else(sample == "2–20 (primary)", 0.20, -0.20),
    estimate_label = sprintf("%.1f", percent_change_for_effj_doubling)
  )

s4c <- ggplot(
  field_data,
  aes(x = percent_change_for_effj_doubling, y = y_pos, colour = sample, shape = sample)
) +
  geom_vline(xintercept = 0, colour = dark_grey, linewidth = 0.45) +
  geom_errorbar(
    aes(xmin = lower, xmax = upper), orientation = "y",
    width = 0, linewidth = 0.75
  ) +
  geom_point(size = 2.7) +
  geom_text(
    aes(y = y_pos + if_else(sample == "2–20 (primary)", 0.15, -0.15),
        label = estimate_label),
    family = font_family, size = 2.9, colour = ink
  ) +
  facet_wrap(~comparison, nrow = 1) +
  scale_y_continuous(
    breaks = seq_along(levels(field_data$field)),
    labels = levels(field_data$field),
    limits = c(0.55, 6.48)
  ) +
  scale_x_continuous(
    limits = c(-43, 30), breaks = c(-40, -20, 0, 20)
  ) +
  scale_colour_manual(values = sample_values) +
  scale_shape_manual(values = sample_shapes) +
  labs(
    x = "Adjusted percent change in CJR when EffJ doubles",
    y = NULL,
    title = "Field estimates in Full OpenAlex",
    tag = "c"
  ) +
  theme_s4() +
  theme(
    legend.position = "none",
    plot.tag = element_text(size = 11.5, face = "bold"),
    plot.tag.position = "topleft"
  )

figure_s4 <- (wrap_elements(full = s4a) | s4b) / s4c +
  plot_layout(widths = c(0.60, 1.80), heights = c(0.78, 1.22))

width_in <- 205 / 25.4
height_in <- 165 / 25.4
stem <- file.path(figure_dir, "figure_s4_no_upper_limit_sensitivity")

ggsave(
  paste0(stem, ".pdf"), figure_s4, device = cairo_pdf,
  width = width_in, height = height_in, units = "in", bg = "white"
)

ragg::agg_tiff(
  paste0(stem, ".tiff"), width = width_in, height = height_in,
  units = "in", res = 300, compression = "lzw", background = "white"
)
print(figure_s4)
dev.off()

ragg::agg_png(
  paste0(stem, ".png"), width = width_in, height = height_in,
  units = "in", res = 200, background = "white"
)
print(figure_s4)
dev.off()

cat("Rendered Figure S4 no-upper-limit sensitivity.\n")
