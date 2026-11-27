const csrf = document.querySelector('meta[name="csrf-token"]').content;
const path = document.querySelector('meta[name="staff-live-path"]')?.content ?? "/staff/live";
const liveSocket = new LiveView.LiveSocket(path, Phoenix.Socket, {
  params: { _csrf_token: csrf },
  hooks: {
    StaffGapQueue: {
      mounted() {
        this.handleEvent("gap-reviewed", ({ id }) => {
          document.getElementById(`gap-heading-${id}`)?.focus();
        });
      },
    },
    StaffForm: {
      disconnected() {
        this.el.querySelector("fieldset").disabled = true;
      },
      reconnected() {
        this.el.querySelector("fieldset").disabled = false;
      },
    },
  },
});
liveSocket.connect();
