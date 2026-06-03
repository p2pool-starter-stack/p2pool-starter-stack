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

const RANGES = [['1h', '1 Hr'], ['24h', '24 Hr'], ['1w', '1 Wk'], ['1m', '1 Mo']];

// Format an epoch-ms x value for the tooltip title. Day + time so long ranges read clearly;
// uses the browser locale (≈ the server's, for a localhost dashboard).
function fmtTimestamp(ms) {
    return new Date(ms).toLocaleString([], {
        month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
    });
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
        const self = this;
        this.chart = new Chart(canvas, {
            type: 'line',
            data: {
                datasets: [
                    { label: 'P2Pool', data: d.p2pool, borderColor: '#58a6ff', tension: 0.3, fill: true,
                      backgroundColor: 'rgba(88,166,255,0.1)', pointRadius: 0, pointHitRadius: 20 },
                    { label: 'XvB', data: d.xvb, borderColor: '#a371f7', tension: 0.3, fill: true,
                      backgroundColor: 'rgba(163, 113, 247, 0.2)', pointRadius: 0, pointHitRadius: 20 },
                    { label: 'Shares', data: d.shares, borderColor: '#FF0000', backgroundColor: '#FF0000',
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
                    // space); axis hidden as before. y unchanged.
                    x: { type: 'linear', display: false },
                    y: { stacked: false, grid: { color: '#30363d' }, ticks: { color: '#8b949e' } },
                },
            },
        });
    }

    sync() {
        if (!this.chart) { this.create(); return; }
        const d = this.props.chart;
        this.shareCounts = d.shares.map((s) => s.c);
        this.chart.data.datasets[0].data = d.p2pool;
        this.chart.data.datasets[1].data = d.xvb;
        this.chart.data.datasets[2].data = d.shares;
        this.chart.data.datasets[2].pointRadius = d.shares.map((s) => s.r);
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
