// ============================================================
// design-tokens.js — NLC satellite brand palette (shared)
// ============================================================

const NLC_DESIGN = {
  brand: "#04A9D2",
  brandHover: "#0396BA",
  brandActive: "#0284A3",
  brandSubtle: "rgba(4, 169, 210, 0.12)",
  brandMuted: "rgba(4, 169, 210, 0.08)",
  brandBorder: "rgba(4, 169, 210, 0.24)",
  success: "#66F78F",
  warning: "#FE7615",
  danger: "#FC365A",
  muted: "#94A3B8",
  white: "#FAFAFA",
  black: "#0F0F0F",
};

const NLC_CHART = {
  brand: NLC_DESIGN.brand,
  brandFill: "rgba(4, 169, 210, 0.15)",
  brandStroke: "rgba(4, 169, 210, 0.85)",
  success: NLC_DESIGN.success,
  warning: NLC_DESIGN.warning,
  danger: NLC_DESIGN.danger,
  muted: NLC_DESIGN.muted,
};

/** Solid plan cover colors (no gradients) */
const NLC_PLAN_COVERS = [
  "#B8E8F5", // brand tint
  "#C8F5D8", // success tint
  "#FFE4CC", // warning tint
  "#D4E4F7", // cool neutral
  "#E8E0F5", // soft lavender neutral
];

/** Avatar / trail member colors — brand-adjacent solids */
const NLC_MEMBER_COLORS = [
  "#04A9D2",
  "#0396BA",
  "#66F78F",
  "#FE7615",
  "#5BB8D4",
  "#0284A3",
  "#8ED4EA",
  "#FC365A",
];

window.NLC_DESIGN = NLC_DESIGN;
window.NLC_CHART = NLC_CHART;
window.NLC_PLAN_COVERS = NLC_PLAN_COVERS;
window.NLC_MEMBER_COLORS = NLC_MEMBER_COLORS;
