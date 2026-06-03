// The hashrate chart. A Preact class component wraps the Chart.js instance imperatively:
// Preact owns the card markup (range buttons + <canvas>), while Chart.js owns the canvas
// pixels. The instance is created on mount and updated in place on each data tick, so it
// survives re-renders (scroll/zoom/animation state intact). It only mounts in the operational
// view, so the canvas is never built into a hidden/zero-size element during Sync Mode.
//
// Points carry their real timestamp as the x value (epoch ms) on a linear scale, so time is to
// scale and outages render as proportional gaps (Issue #65) — a linear scale (not Chart.js's
// `time` scale) avoids vendoring a date-adapter library. The server inserts {x, y: null} break
// markers across outages so the line/fill doesn't span them.
import { Component, createRef, html } from './preact.mjs';
import { fmtTimestamp } from './logic.mjs';

const RANGES = [['1h', '1 Hr'], ['24h', '24 Hr'], ['1w', '1 Wk'], ['1m', '1 Mo']];

// Append an 8-bit alpha to a #rrggbb hex (Chart.js accepts #rrggbbaa). Non-hex values pass
// through opaque, so a future palette change can't break the fills.
const withAlpha = (hex, aa) => (/^#[0-9a-fA-F]{6}$/.test(hex) ? hex + aa : hex);

// The chart's colours, read from the active theme's CSS variables (Issue #43) so the chart
// matches light/dark/auto. Re-read on every sync() so a theme switch recolours it in place.
function paletteColors() {
    const cs = getComputedStyle(document.documentElement);
    const v = (name, fallback) => cs.getPropertyValue(name).trim() || fallback;
    const accent = v('--accent', '#58a6ff');
    const purple = v('--purple', '#a371f7');
    return {
        accent, purple,
        accentFill: withAlpha(accent, '1a'),   // ≈ 0.1 alpha
        purpleFill: withAlpha(purple, '33'),   // ≈ 0.2 alpha
        shares: v('--bad', '#da3633'),
        grid: v('--border', '#30363d'),
        ticks: v('--text-muted', '#8b949e'),
    };
}

export class ChartCard extends Component {
    constructor(props) {
        super(props);
        this.canvasRef = createRef();
        this.shareCounts = [];
    }

    componentDidMount() { this.create(); }
    componentDidUpdate() { this.sync(); }
    componentWillUnmount() {
        if (this.chart) { this.chart.destroy(); this.chart = null; }
    }

    create() {
        const canvas = this.canvasRef.current;
        if (!canvas || typeof Chart === 'undefined') return;
        const d = this.props.chart;
        this.shareCounts = d.shares.map((s) => s.c);
        const c = paletteColors();
        const self = this;
        this.chart = new Chart(canvas, {
            type: 'line',
            data: {
                datasets: [
                    { label: 'P2Pool', data: d.p2pool, borderColor: c.accent, tension: 0.3, fill: true,
                      backgroundColor: c.accentFill, pointRadius: 0, pointHitRadius: 20 },
                    { label: 'XvB', data: d.xvb, borderColor: c.purple, tension: 0.3, fill: true,
                      backgroundColor: c.purpleFill, pointRadius: 0, pointHitRadius: 20 },
                    { label: 'Shares', data: d.shares, borderColor: c.shares, backgroundColor: c.shares,
                      pointStyle: 'triangle', rotation: 180, pointRadius: d.shares.map((s) => s.r),
                      pointHoverRadius: 15, pointHitRadius: 100, showLine: false },
                ],
            },
            options: {
                responsive: true, maintainAspectRatio: false, animation: false,
                spanGaps: false,   // {x, y: null} break markers split the line across outages
                interaction: { mode: 'nearest', axis: 'x', intersect: false },
                plugins: {
                    legend: { display: false },
                    tooltip: { callbacks: {
                        title(items) { return items.length ? fmtTimestamp(items[0].parsed.x) : ''; },
                        label(context) {
                            if (context.dataset.label === 'Shares') return self.shareCounts[context.dataIndex] + ' Shares';
                            let label = context.dataset.label || '';
                            if (label) label += ': ';
                            if (context.parsed.y !== null) label += context.parsed.y + ' H/s';
                            return label;
                        },
                    } },
                },
                scales: {
                    // Linear x positions points by real elapsed time (gaps occupy proportional
                    // space); axis hidden as before. y grid/ticks follow the theme.
                    x: { type: 'linear', display: false },
                    y: { stacked: false, grid: { color: c.grid }, ticks: { color: c.ticks } },
                },
            },
        });
    }

    sync() {
        if (!this.chart) { this.create(); return; }
        const d = this.props.chart;
        const c = paletteColors();   // re-read so a theme switch recolours in place
        this.shareCounts = d.shares.map((s) => s.c);
        const ds = this.chart.data.datasets;
        ds[0].data = d.p2pool; ds[0].borderColor = c.accent; ds[0].backgroundColor = c.accentFill;
        ds[1].data = d.xvb;    ds[1].borderColor = c.purple; ds[1].backgroundColor = c.purpleFill;
        ds[2].data = d.shares; ds[2].borderColor = c.shares; ds[2].backgroundColor = c.shares;
        ds[2].pointRadius = d.shares.map((s) => s.r);
        this.chart.options.scales.y.grid.color = c.grid;
        this.chart.options.scales.y.ticks.color = c.ticks;
        this.chart.update();
        this.chart.resize();
    }

    render({ range, onRange }) {
        return html`
        <div class="card">
            <div class="chart-controls">
                <span class="text-muted text-small mr-1">Range:</span>
                ${RANGES.map(([r, label]) => html`<a href=${'?range=' + r}
                    class=${'btn-range' + (range === r ? ' active' : '')}
                    onClick=${(e) => { e.preventDefault(); onRange(r); }}>${label}</a>`)}
            </div>
            <div class="chart-wrap"><canvas ref=${this.canvasRef}></canvas></div>
        </div>`;
    }
}
