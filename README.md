# FinEase Loan Portfolio Risk & Collection Analytics

End-to-end credit risk analysis, delinquency tracking, and Excel KPI reporting across **80,000 disbursed loans** (`₹1,492.80 Cr` principal) and **53 branches** spanning **Gujarat** and **Maharashtra**.



## Key Portfolio Highlights (`2026-09-30` Snapshot)

| Metric | Value | Notes |
| :--- | :---: | :--- |
| **Total Disbursed Loans** | **80,000** | `₹1,492.80 Cr` sanctioned principal (`₹1,86,600` avg ticket) |
| **Active Open Loans (`2026-09-30`)** | **50,811** | `₹557.74 Cr` active outstanding balance |
| **Simple / Weighted Avg Rate** | **14.75% / 15.50%** | Ranges from `9.00%` (Gold) to `24.00%` (Personal) |
| **Gross NPA (`90+ DPD`)** | **9.16%** | `₹51.10 Cr` across `3,576` active NPA accounts |
| **Watchlist (`31–90 DPD`)** | **₹37.13 Cr** | `₹22.22 Cr` (`31–60 DPD`) + `₹14.91 Cr` (`61–90 DPD`) |
| **Ever-NPA Rate (`90+ DPD` History)** | **9.12%** | `7,295` loans (`₹139.93 Cr` issued principal) ever hit `90+ DPD` |
| **Overall Collection Efficiency** | **53.52%** | `₹969.20 Cr` collected against scheduled EMIs |

---

## Segment & Regional Breakdown

### By Loan Product
| Product | Total Loans | Disbursed (₹ Cr) | Weighted Avg Rate | Active Balance (`Sep 2026`) | Gross NPA % |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Personal** | 28,023 | ₹769.36 Cr | 18.50% | ₹339.01 Cr | **10.61%** |
| **Two-Wheeler** | 35,926 | ₹377.79 Cr | 13.50% | ₹161.67 Cr | **8.39%** |
| **Gold** | 16,051 | ₹345.65 Cr | 11.01% | ₹57.08 Cr | **2.78%** |

### By State
| State | Total Loans | Disbursed (₹ Cr) | Active Balance (`Sep 2026`) | Gross NPA (`90+ DPD`) | Gross NPA % |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Gujarat** | 42,045 | ₹784.75 Cr | ₹291.98 Cr | ₹26.35 Cr | **9.02%** |
| **Maharashtra** | 37,955 | ₹708.05 Cr | ₹265.77 Cr | ₹24.76 Cr | **9.32%** |

### DPD Bucket Distribution (`2026-09-30`)
* **Current (`0 DPD`):** `39,496` loans | `₹410.96 Cr` (`73.68%`)
* **1–30 DPD:** `4,657` loans | `₹58.54 Cr` (`10.50%`)
* **31–60 DPD:** `1,887` loans | `₹22.22 Cr` (`3.98%`) — *`45.28%` roll rate into `61–90 DPD`*
* **61–90 DPD:** `1,195` loans | `₹14.91 Cr` (`2.67%`) — *`44.37%` roll rate into `90+ DPD`*
* **90+ DPD (Gross NPA):** `3,576` loans | `₹51.10 Cr` (`9.16%`)

---

## Repository & Work Structure

```text
FinEase-Loan-Portfolio-Analytics/
├── data/
│   ├── loans.csv                        # 80,000 loan origination records (principal, rate, tenure, EMI)
│   ├── branches.csv                     # 53 branch mappings across Gujarat & Maharashtra
│   ├── emi_schedule.csv                 # Scheduled monthly EMI obligations
│   ├── payments.csv                     # Customer repayment transactions
│   └── monthly_balance_snapshot.csv     # 863,395 month-end balance, DPD, and bucket snapshots
├── excel_model/
│   └── FinEase_Risk_Dashboard.xlsx      # 7-tab interactive risk & collection workbook
├── presentation/
│   └── finease_risk_presentation.pptx   # Executive risk & implementation slide deck
└── README.md
