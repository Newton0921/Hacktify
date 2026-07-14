#!/usr/bin/env python3
"""
Generate Assessment.xlsx for Stage 1 — VPN Gateway.
Uses openpyxl to create a properly formatted scoring spreadsheet.
"""
import openpyxl
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter
import os

def generate_assessment():
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Stage 1 Assessment"

    # Styles
    header_font = Font(name="Calibri", bold=True, size=12, color="FFFFFF")
    header_fill = PatternFill(start_color="2F5496", end_color="2F5496", fill_type="solid")
    header_align = Alignment(horizontal="center", vertical="center", wrap_text=True)

    row_font = Font(name="Calibri", size=11)
    row_align = Alignment(vertical="center", wrap_text=True)

    border = Border(
        left=Side(style="thin"),
        right=Side(style="thin"),
        top=Side(style="thin"),
        bottom=Side(style="thin"),
    )

    # Title row
    ws.merge_cells("A1:E1")
    title_cell = ws["A1"]
    title_cell.value = "Stage 1 — Remote Access Gateway Assessment"
    title_cell.font = Font(name="Calibri", bold=True, size=14, color="2F5496")
    title_cell.alignment = Alignment(horizontal="center", vertical="center")
    ws.row_dimensions[1].height = 30

    # Blank row
    ws.row_dimensions[2].height = 10

    # Headers
    headers = ["Objective", "Points", "Evidence Required", "Tripwire Penalty", "Pass/Fail Criteria"]
    col_widths = [40, 10, 35, 20, 40]

    for col_idx, (header, width) in enumerate(zip(headers, col_widths), start=1):
        cell = ws.cell(row=3, column=col_idx, value=header)
        cell.font = header_font
        cell.fill = header_fill
        cell.alignment = header_align
        cell.border = border
        ws.column_dimensions[get_column_letter(col_idx)].width = width

    # Data rows
    data = [
        [
            "Gain authenticated access to vpn-gateway via field technician credential",
            100,
            "Shadow hash extracted from /etc/openvpn/server/field_accounts.conf",
            "N/A",
            "Submitted flag FLAG{S1-...} matches stored value computed from "
            "HMAC-SHA256(INSTANCE_SEED, 'STAGE1:<artifact_line>')"
        ],
    ]

    for row_idx, row_data in enumerate(data, start=4):
        for col_idx, value in enumerate(row_data, start=1):
            cell = ws.cell(row=row_idx, column=col_idx, value=value)
            cell.font = row_font
            cell.alignment = row_align
            cell.border = border
        ws.row_dimensions[row_idx].height = 50

    # Save
    script_dir = os.path.dirname(os.path.abspath(__file__))
    output_path = os.path.join(script_dir, "Assessment.xlsx")
    wb.save(output_path)
    print(f"[+] Assessment.xlsx written to {output_path}")


if __name__ == "__main__":
    generate_assessment()
