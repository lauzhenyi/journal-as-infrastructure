#!/usr/bin/env Rscript

# Render the broad-field journal proxy threshold sensitivity figure.

suppressPackageStartupMessages({
  library(ggplot2)
  library(readr)
})

arguments <- commandArgs(trailingOnly = TRUE)
project_root <- if (length(arguments) >= 1L) arguments[[1]] else "."
input_path <- if (length(arguments) >= 2L) {
  arguments[[2]]
} else {
  file.path(
    project_root,
    "results",
    "direct_outcome_gap",
    "broad_field_journal_proxy_results.csv"
  )
}
output_path <- if (length(arguments) >= 3L) {
  arguments[[3]]
} else {
  file.path(
    project_root,
    "results",
    "direct_outcome_gap",
    "figures",
    "appendix",
    "figure_s5_broad_field_journal_proxy.pdf"
  )
}

data <- read_csv(input_path, show_col_types = FALSE)
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
data$threshold_label <- factor(
  sprintf("%.1f (%d journals; %s model pairs)",
          data$minimum_effective_fields,
          data$journal_count,
          format(data$model_observations, big.mark = ",")),
  levels = rev(sprintf("%.1f (%d journals; %s model pairs)",
                       data$minimum_effective_fields,
                       data$journal_count,
                       format(data$model_observations, big.mark = ",")))
)

plot <- ggplot(
  data,
  aes(x = cjr_change_percent_for_effj_doubling, y = threshold_label)
) +
  geom_vline(xintercept = 0, colour = "#666666", linewidth = 0.45) +
  geom_errorbar(
    aes(xmin = confidence_low, xmax = confidence_high),
    orientation = "y",
    width = 0,
    linewidth = 0.75,
    colour = "#0072B2"
  ) +
  geom_point(size = 2.7, colour = "#0072B2") +
  scale_x_continuous(breaks = seq(-40, 20, 10), limits = c(-40, 20)) +
  labs(
    x = "Adjusted CJR change (%) when EffJ doubles",
    y = "Minimum effective number of fields"
  ) +
  theme_classic(base_family = "Arial", base_size = 10) +
  theme(
    axis.title = element_text(colour = "#171717"),
    axis.text = element_text(colour = "#171717"),
    plot.margin = margin(6, 8, 6, 6)
  )

ggsave(
  output_path,
  plot,
  device = cairo_pdf,
  width = 183 / 25.4,
  height = 82 / 25.4,
  units = "in",
  bg = "white"
)
