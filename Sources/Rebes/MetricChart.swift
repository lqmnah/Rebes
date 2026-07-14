//
//  MetricChart.swift
//  Rebes
//
//  Reusable area chart with a gradient fill (AlDente-style), on a glass card.
//

import SwiftUI
import Charts

struct MetricChart: View {
    let title: String
    let latest: String
    let points: [MetricPoint]
    var accent: Color = Theme.teal
    var unitSuffix: String = ""
    /// Fixed y-range; nil = auto.
    var yRange: ClosedRange<Double>? = nil

    var body: some View {
        LQCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(latest)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                }
                if points.count < 2 {
                    HStack { Spacer(); Text("Collecting…").font(.system(size: 11)).foregroundStyle(.secondary); Spacer() }
                        .frame(height: 90)
                } else {
                    Chart(points) { p in
                        AreaMark(x: .value("t", p.t), y: .value(title, p.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(
                                colors: [accent.opacity(0.35), accent.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("t", p.t), y: .value(title, p.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(accent)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .trailing) { v in
                            AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                            AxisValueLabel {
                                if let d = v.as(Double.self) {
                                    Text("\(Int(d))\(unitSuffix)").font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .modifier(YRange(range: yRange))
                    .frame(height: 90)
                }
            }
        }
    }
}

private struct YRange: ViewModifier {
    let range: ClosedRange<Double>?
    func body(content: Content) -> some View {
        if let range { content.chartYScale(domain: range) } else { content }
    }
}
