// Native BlueZ D-Bus agent helper for Bluetooth pairing
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <dbus/dbus.h>

#define AGENT_PATH "/org/noctalia/bluetooth_helper"
#define JSON_PATH  "/tmp/noctalia_bt_pairing.json"
#define ACT_PATH   "/tmp/noctalia_bt_pairing_action"

static void clean_files(void) {
    unlink(JSON_PATH);
    unlink(ACT_PATH);
}

// Extract MAC address and alias from D-Bus object path
static void get_device_info(DBusConnection *conn, const char *dev_path, char *addr, char *name) {
    strcpy(addr, dev_path);
    strcpy(name, "Bluetooth Device");
    const char *p = strstr(dev_path, "dev_");
    if (p) {
        strncpy(addr, p + 4, 17);
        addr[17] = '\0';
        for (int i = 0; addr[i]; i++) if (addr[i] == '_') addr[i] = ':';
    }
    DBusMessage *msg = dbus_message_new_method_call("org.bluez", dev_path, "org.freedesktop.DBus.Properties", "Get");
    if (!msg) return;
    const char *iface = "org.bluez.Device1", *prop_name = "Alias";
    dbus_message_append_args(msg, DBUS_TYPE_STRING, &iface, DBUS_TYPE_STRING, &prop_name, DBUS_TYPE_INVALID);
    DBusMessage *reply = dbus_connection_send_with_reply_and_block(conn, msg, 1000, NULL);
    dbus_message_unref(msg);
    if (reply) {
        DBusMessageIter iter, sub;
        if (dbus_message_iter_init(reply, &iter) && dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_VARIANT) {
            dbus_message_iter_recurse(&iter, &sub);
            if (dbus_message_iter_get_arg_type(&sub) == DBUS_TYPE_STRING) {
                const char *val;
                dbus_message_iter_get_basic(&sub, &val);
                if (val && *val) strncpy(name, val, 63);
            }
        }
        dbus_message_unref(reply);
    }
}

static int wait_user_action(void) {
    time_t t0 = time(NULL);
    while (time(NULL) - t0 < 20) {
        FILE *f = fopen(ACT_PATH, "r");
        if (f) {
            char buf[32] = {0};
            if (fgets(buf, sizeof(buf), f)) {
                fclose(f);
                clean_files();
                return (strcasestr(buf, "accept") != NULL || strcasestr(buf, "yes") != NULL);
            }
            fclose(f);
        }
        usleep(50000);
    }
    clean_files();
    return 0;
}

// Write pairing details to JSON and await user response
static int handle_req(DBusConnection *conn, const char *dev_path, const char *passkey, int wait) {
    char addr[64] = {0}, name[64] = {0};
    get_device_info(conn, dev_path, addr, name);
    FILE *f = fopen(JSON_PATH, "w");
    if (f) {
        fprintf(f, "{\"address\":\"%s\",\"name\":\"%s\",\"passkey\":\"%s\",\"timestamp\":%ld}\n", addr, name, passkey ? passkey : "", (long)time(NULL));
        fflush(f);
        fclose(f);
    }
    char cmd[256];
    if (passkey && *passkey) snprintf(cmd, sizeof(cmd), "notify-send -u normal -t 6000 'Network Toolkit' '%s requested to pair (PIN: %s)' 2>/dev/null", name, passkey);
    else snprintf(cmd, sizeof(cmd), "notify-send -u normal -t 6000 'Network Toolkit' '%s requested to pair' 2>/dev/null", name);
    system(cmd);
    return wait ? wait_user_action() : 1;
}

static DBusHandlerResult agent_filter(DBusConnection *conn, DBusMessage *msg, void *user_data) {
    const char *member = dbus_message_get_member(msg);
    if (!member) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

    if (strcmp(member, "Release") == 0) {
        DBusMessage *reply = dbus_message_new_method_return(msg);
        dbus_connection_send(conn, reply, NULL);
        dbus_message_unref(reply);
        return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "AuthorizeService") == 0) {
        DBusMessage *reply = dbus_message_new_method_return(msg);
        dbus_connection_send(conn, reply, NULL);
        dbus_message_unref(reply);
        return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "RequestAuthorization") == 0) {
        const char *dev = NULL;
        dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &dev, DBUS_TYPE_INVALID);
        if (handle_req(conn, dev ? dev : "", "", 1)) {
            DBusMessage *reply = dbus_message_new_method_return(msg);
            dbus_connection_send(conn, reply, NULL);
            dbus_message_unref(reply);
        } else {
            DBusMessage *err = dbus_message_new_error(msg, "org.bluez.Error.Rejected", "Pairing rejected");
            dbus_connection_send(conn, err, NULL);
            dbus_message_unref(err);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "RequestConfirmation") == 0) {
        const char *dev = NULL;
        dbus_uint32_t passkey = 0;
        dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &dev, DBUS_TYPE_UINT32, &passkey, DBUS_TYPE_INVALID);
        char pbuf[16];
        snprintf(pbuf, sizeof(pbuf), "%06u", passkey);
        if (handle_req(conn, dev ? dev : "", pbuf, 1)) {
            DBusMessage *reply = dbus_message_new_method_return(msg);
            dbus_connection_send(conn, reply, NULL);
            dbus_message_unref(reply);
        } else {
            DBusMessage *err = dbus_message_new_error(msg, "org.bluez.Error.Rejected", "Pairing rejected");
            dbus_connection_send(conn, err, NULL);
            dbus_message_unref(err);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "RequestPasskey") == 0) {
        const char *dev = NULL;
        dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &dev, DBUS_TYPE_INVALID);
        if (handle_req(conn, dev ? dev : "", "", 1)) {
            DBusMessage *reply = dbus_message_new_method_return(msg);
            dbus_uint32_t passkey = 0;
            dbus_message_append_args(reply, DBUS_TYPE_UINT32, &passkey, DBUS_TYPE_INVALID);
            dbus_connection_send(conn, reply, NULL);
            dbus_message_unref(reply);
        } else {
            DBusMessage *err = dbus_message_new_error(msg, "org.bluez.Error.Rejected", "Pairing rejected");
            dbus_connection_send(conn, err, NULL);
            dbus_message_unref(err);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "RequestPinCode") == 0) {
        const char *dev = NULL;
        dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &dev, DBUS_TYPE_INVALID);
        if (handle_req(conn, dev ? dev : "", "0000", 1)) {
            DBusMessage *reply = dbus_message_new_method_return(msg);
            const char *pin = "0000";
            dbus_message_append_args(reply, DBUS_TYPE_STRING, &pin, DBUS_TYPE_INVALID);
            dbus_connection_send(conn, reply, NULL);
            dbus_message_unref(reply);
        } else {
            DBusMessage *err = dbus_message_new_error(msg, "org.bluez.Error.Rejected", "Pairing rejected");
            dbus_connection_send(conn, err, NULL);
            dbus_message_unref(err);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "DisplayPasskey") == 0) {
        const char *dev = NULL;
        dbus_uint32_t passkey = 0;
        dbus_uint16_t entered = 0;
        dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &dev, DBUS_TYPE_UINT32, &passkey, DBUS_TYPE_UINT16, &entered, DBUS_TYPE_INVALID);
        char pbuf[16];
        snprintf(pbuf, sizeof(pbuf), "%06u", passkey);
        handle_req(conn, dev ? dev : "", pbuf, 0);
        DBusMessage *reply = dbus_message_new_method_return(msg);
        dbus_connection_send(conn, reply, NULL);
        dbus_message_unref(reply);
        return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "DisplayPinCode") == 0) {
        const char *dev = NULL, *pin = NULL;
        dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &dev, DBUS_TYPE_STRING, &pin, DBUS_TYPE_INVALID);
        handle_req(conn, dev ? dev : "", pin ? pin : "", 0);
        DBusMessage *reply = dbus_message_new_method_return(msg);
        dbus_connection_send(conn, reply, NULL);
        dbus_message_unref(reply);
        return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "Cancel") == 0) {
        clean_files();
        DBusMessage *reply = dbus_message_new_method_return(msg);
        dbus_connection_send(conn, reply, NULL);
        dbus_message_unref(reply);
        return DBUS_HANDLER_RESULT_HANDLED;
    }
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

int main(void) {
    clean_files();
    DBusError err;
    dbus_error_init(&err);
    DBusConnection *conn = dbus_bus_get(DBUS_BUS_SYSTEM, &err);
    if (!conn) return 1;

    DBusObjectPathVTable vtable = { .message_function = agent_filter };
    dbus_connection_register_object_path(conn, AGENT_PATH, &vtable, NULL);

    const char *path = AGENT_PATH, *cap = "KeyboardDisplay";
    DBusMessage *msg = dbus_message_new_method_call("org.bluez", "/org/bluez", "org.bluez.AgentManager1", "RegisterAgent");
    if (msg) {
        dbus_message_append_args(msg, DBUS_TYPE_OBJECT_PATH, &path, DBUS_TYPE_STRING, &cap, DBUS_TYPE_INVALID);
        DBusMessage *rep = dbus_connection_send_with_reply_and_block(conn, msg, 2000, NULL);
        if (rep) dbus_message_unref(rep);
        dbus_message_unref(msg);
    }

    msg = dbus_message_new_method_call("org.bluez", "/org/bluez", "org.bluez.AgentManager1", "RequestDefaultAgent");
    if (msg) {
        dbus_message_append_args(msg, DBUS_TYPE_OBJECT_PATH, &path, DBUS_TYPE_INVALID);
        DBusMessage *rep = dbus_connection_send_with_reply_and_block(conn, msg, 2000, NULL);
        if (rep) dbus_message_unref(rep);
        dbus_message_unref(msg);
    }

    system("bluetoothctl discoverable on 2>/dev/null; bluetoothctl pairable on 2>/dev/null");

    while (dbus_connection_read_write_dispatch(conn, -1)) {}
    return 0;
}
